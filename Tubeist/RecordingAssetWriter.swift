import AVFoundation
import UniformTypeIdentifiers

private final class AssetWriterFinishContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(AVAssetWriter.Status, String?), Never>?

    init(_ continuation: CheckedContinuation<(AVAssetWriter.Status, String?), Never>) {
        self.continuation = continuation
    }

    func resume(status: AVAssetWriter.Status, message: String?) {
        let continuation = lock.withLock {
            let current = self.continuation
            self.continuation = nil
            return current
        }
        continuation?.resume(returning: (status, message))
    }
}

private final class SendableAssetWriterFinishHandle: @unchecked Sendable {
    private let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }

    func cancelWriting() {
        writer.cancelWriting()
    }

    var status: AVAssetWriter.Status {
        writer.status
    }

    var errorDescription: String? {
        writer.error?.localizedDescription
    }
}

final class AssetWriterFinalizationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ value: Bool) {
        lock.withLock { self.value = value }
    }

    func read() -> Bool {
        lock.withLock { value }
    }
}

/// Each recording owns a fresh signal shared by its file and MP4 writers.
/// File callbacks can fail independently of AVAssetWriter's status.
final class RecordingFileFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?

    func report(_ message: String) {
        lock.withLock { if self.message == nil { self.message = message } }
    }

    func check() throws {
        if let message = lock.withLock({ message }) {
            throw MediaEncodingError.invalid(message)
        }
    }
}

/// Passthrough AAC is laid out by packet duration in AVAssetWriter. Track that
/// actual file timeline, so rounding a gap to whole packets cannot accumulate
/// across repeated recoveries. The maximum error is half an AAC packet.
struct RecordingAudioTimeline {
    private(set) var end: CMTime?

    func needsSilence(before pts: CMTime, packetDuration: CMTime) throws -> Bool {
        guard pts.isNumeric, packetDuration.isNumeric, packetDuration > .zero else {
            throw MediaEncodingError.invalid("Invalid recording audio timing")
        }
        guard let end else { return false }
        let gap = CMTimeSubtract(pts, end)
        // The capture watchdog fails after 30 seconds. Bound work even if a
        // malformed timestamp somehow reaches the recording beyond recovery.
        guard gap.seconds <= 60 else { throw MediaEncodingError.invalid("Recording audio gap exceeds 60 seconds") }
        return gap > CMTimeMultiplyByRatio(packetDuration, multiplier: 1, divisor: 2)
    }

    mutating func appended(pts: CMTime, duration: CMTime) {
        end = CMTimeAdd(end ?? pts, duration)
    }
}

@PipelineActor
final class RecordingAssetWriter {
    nonisolated let fileFailure = RecordingFileFailure()
    private let writer: AVAssetWriter
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var video: [CMSampleBuffer] = []
    private var audio: [CMSampleBuffer] = []
    private var audioTimeline = RecordingAudioTimeline()
    private var silencePacket: CMSampleBuffer?
    private var started = false
    private var lastFlushPTS = CMTime.zero
    private let finalizationFlag: AssetWriterFinalizationFlag
    var identifier: ObjectIdentifier { ObjectIdentifier(writer) }

    init(delegate: any AVAssetWriterDelegate, finalizationFlag: AssetWriterFinalizationFlag) throws {
        guard let type = UTType(AVFileType.mp4.rawValue) else {
            throw MediaEncodingError.invalid("MP4 is unavailable")
        }
        writer = AVAssetWriter(contentType: type)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        // Automatic mixed A/V segmentation does not support passthrough.
        // Both tracks are already compressed; flush recording fragments manually.
        writer.preferredOutputSegmentInterval = .indefinite
        writer.initialSegmentStartTime = .zero
        writer.movieTimeScale = 90_000
        writer.delegate = delegate
        self.finalizationFlag = finalizationFlag
        finalizationFlag.set(false)
    }

    func append(_ sample: CMSampleBuffer, kind: ISOBMFFTrackKind) throws {
        try fileFailure.check()
        guard let format = CMSampleBufferGetFormatDescription(sample) else {
            throw MediaEncodingError.invalid("Recording sample has no format")
        }
        if kind == .video {
            if videoInput == nil { videoInput = makeInput(.video, format: format) }
            video.append(sample)
        } else {
            if audioInput == nil { audioInput = makeInput(.audio, format: format) }
            audio.append(sample)
        }
        if !started, let videoInput, let audioInput {
            guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
                throw MediaEncodingError.invalid("Could not add compressed media inputs")
            }
            writer.add(videoInput)
            writer.add(audioInput)
            guard writer.startWriting() else {
                throw MediaEncodingError.invalid(writer.error?.localizedDescription ?? "Writer could not start")
            }
            writer.startSession(atSourceTime: .zero)
            started = true
        }
        try drain()
        for pending in [video, audio] {
            if let first = pending.first, let last = pending.last,
               CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(last), CMSampleBufferGetPresentationTimeStamp(first)).seconds > 4 {
                throw MediaEncodingError.invalid("Recording storage cannot keep up")
            }
        }
    }

    private func makeInput(_ type: AVMediaType, format: CMFormatDescription) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: type, outputSettings: nil, sourceFormatHint: format)
        // movieTimeScale does not set the video track's default (600 Hz).
        // Keep the corrected decode lead and shared A/V epoch at transport precision.
        if type == .video { input.mediaTimeScale = 90_000 }
        input.expectsMediaDataInRealTime = true
        return input
    }

    private func drain() throws {
        try fileFailure.check()
        guard started else { return }
        // A failed writer stops reporting readiness instead of rejecting an
        // append; report it now rather than as a growing backlog.
        guard writer.status == .writing else {
            throw MediaEncodingError.invalid(writer.error?.localizedDescription ?? "The recording writer stopped")
        }
        var paddedPackets = 0
        while true {
            var progress = false
            if let input = videoInput, input.isReadyForMoreMediaData, let sample = video.first {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
                let sync = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
                if sync, CMTimeSubtract(pts, lastFlushPTS).seconds >= 1.98 {
                    writer.flushSegment()
                    lastFlushPTS = pts
                }
                guard input.append(sample) else { throw appendError() }
                video.removeFirst()
                progress = true
            }
            if let input = audioInput, input.isReadyForMoreMediaData, let sample = audio.first {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let duration = CMSampleBufferGetDuration(sample)
                if try audioTimeline.needsSilence(before: pts, packetDuration: duration), let end = audioTimeline.end {
                    // Do not let a long recovery monopolize capture processing.
                    // Padding is produced lazily, never queued as seconds of PCM.
                    guard paddedPackets < 64 else { return }
                    let padding = try makeSilence(at: end, matching: sample)
                    guard input.append(padding) else { throw appendError() }
                    audioTimeline.appended(pts: end, duration: CMSampleBufferGetDuration(padding))
                    paddedPackets += 1
                } else {
                    guard input.append(sample) else { throw appendError() }
                    audioTimeline.appended(pts: pts, duration: duration)
                    audio.removeFirst()
                }
                progress = true
            }
            if !progress { return }
        }
    }

    private func makeSilence(at pts: CMTime, matching sample: CMSampleBuffer) throws -> CMSampleBuffer {
        guard let format = CMSampleBufferGetFormatDescription(sample) else {
            throw MediaEncodingError.invalid("Recording audio has no format")
        }
        if silencePacket == nil || !CMFormatDescriptionEqual(CMSampleBufferGetFormatDescription(silencePacket!), otherFormatDescription: format) {
            silencePacket = try AACAudioEncoder.silencePacket(matching: format)
        }
        guard let silencePacket else { throw MediaEncodingError.invalid("Recording silence is unavailable") }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(silencePacket),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        try checkMediaStatus(CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: silencePacket,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy), "Timing recording silence")
        guard let copy else { throw MediaEncodingError.invalid("Could not time recording silence") }
        return copy
    }

    private func appendError() -> MediaEncodingError {
        .invalid( writer.error?.localizedDescription ?? "Writer rejected compressed media")
    }

    func finish(deadline: ContinuousClock.Instant) async throws {
        try fileFailure.check()
        guard started else {
            writer.cancelWriting()
            throw MediaEncodingError.invalid("Recording produced no video frames")
        }
        while !video.isEmpty || !audio.isEmpty {
            guard ContinuousClock().now < deadline else {
                writer.cancelWriting()
                throw MediaEncodingError.invalid("Recording did not drain before its shutdown deadline")
            }
            try drain()
            if !video.isEmpty || !audio.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        }
        guard writer.status == .writing else {
            throw MediaEncodingError.invalid(writer.error?.localizedDescription ?? "The recording writer stopped")
        }
        finalizationFlag.set(true)
        let handle = SendableAssetWriterFinishHandle(writer)
        let result = await withCheckedContinuation { continuation in
            let once = AssetWriterFinishContinuation(continuation)
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            let remaining = max(.zero, ContinuousClock().now.duration(to: deadline))
            let timeout = Task.detached {
                do { try await Task.sleep(for: remaining) } catch { return }
                handle.cancelWriting()
                once.resume(status: .cancelled, message: "Recording exceeded its shutdown deadline")
            }
            writer.finishWriting {
                timeout.cancel()
                once.resume(status: handle.status, message: handle.errorDescription)
            }
        }
        guard result.0 == .completed else {
            throw MediaEncodingError.invalid(result.1 ?? "Recording failed")
        }
        try fileFailure.check()
    }

    func cancel() { writer.cancelWriting() }

    /// Ends the recording after a write or storage failure while the session
    /// continues. A writer that is still healthy (storage fell behind) finishes
    /// with the media it already accepted; a failed writer can only be cancelled.
    /// Fragments already delivered to the recording file remain in either case.
    func finishAfterFailure(deadline: ContinuousClock.Instant) async {
        if started, writer.status == .writing {
            do { try await finish(deadline: deadline); return } catch {}
        }
        if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
        video.removeAll()
        audio.removeAll()
    }
}
