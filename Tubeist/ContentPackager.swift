//
//  ContentPackager.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-05.
//

// @preconcurrency needed to pass CMSampleBuffer around
import AVFoundation
import VideoToolbox

enum MediaType {
    case audio
    case video
}

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

private final class OneShotBoolContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Bool) {
        let continuation = lock.withLock {
            let current = self.continuation
            self.continuation = nil
            return current
        }
        continuation?.resume(returning: value)
    }
}

@PipelineActor
private class AssetWriterActor {
    private var fragmentAssetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var stream: Bool = Settings.stream
    private var record: Bool = Settings.record
    private var finalizing: Bool = false
    private var hasStartedSession: Bool = false
    private var baseVideoPTS: CMTime? = nil
    private let writerTimeScale: CMTimeScale = 90000
    private var startupAudio: [CMSampleBuffer] = []
    private var pendingAudio: [CMSampleBuffer] = []
    private var pendingVideo: [CMSampleBuffer] = []
    private var pendingTrimmedAudioSamples = 0
    private var pendingTrimmedVideoSamples = 0
    private var startupTrimmedAudioSamples = 0
    private var lastTrimLogTime: Date?
    private let trimLogInterval: TimeInterval = 5
    private var terminalError: ContentPackagingError?
    
    func setupFragmentAssetWriter(stream: Bool, record: Bool) async -> Bool {
        finalizing = false
        terminalError = nil
        guard let contentType = UTType(AVFileType.mp4.rawValue) else {
            LOG("MP4 is not a valid type", level: .error)
            return false
        }
        fragmentAssetWriter = AVAssetWriter(contentType: contentType)
        guard let fragmentAssetWriter else {
            LOG("Could not create asset writer", level: .error)
            return false
        }
        let selectedPreset = Settings.selectedPreset
        let selectedVideoBitrate = selectedPreset.videoBitrate
        let selectedAudioBitrate = selectedPreset.audioBitrate
        let selectedAudioChannels = selectedPreset.audioChannels
        let selectedWidth = selectedPreset.width
        let selectedHeight = selectedPreset.height
        let selectedKeyframeInterval = selectedPreset.keyframeInterval
        let selectedFrameRate = selectedPreset.frameRate
        let frameIntervalKey = Int(ceil(selectedKeyframeInterval * selectedFrameRate))
        let adjustedFragmentDuration = selectedFrameRate / trunc(selectedFrameRate / FRAGMENT_DURATION)
        
        LOG("\(selectedPreset.description)", level: .debug)
        
        fragmentAssetWriter.shouldOptimizeForNetworkUse = true
        fragmentAssetWriter.outputFileTypeProfile = .mpeg4AppleHLS
        fragmentAssetWriter.preferredOutputSegmentInterval = CMTime(seconds: adjustedFragmentDuration, preferredTimescale: FRAGMENT_TIMESCALE)
        fragmentAssetWriter.movieTimeScale = writerTimeScale
        fragmentAssetWriter.initialSegmentStartTime = .zero
        fragmentAssetWriter.delegate = ContentPackager.shared
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: selectedWidth,
            AVVideoHeightKey: selectedHeight,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                AVVideoAverageBitRateKey: selectedVideoBitrate,
                AVVideoExpectedSourceFrameRateKey: selectedFrameRate,
                AVVideoMaxKeyFrameIntervalKey: frameIntervalKey,
                // I believe we need this since we are async and frames can potentially arrive out of order
                AVVideoAllowFrameReorderingKey: true,
                kVTCompressionPropertyKey_HDRMetadataInsertionMode: kVTHDRMetadataInsertionMode_Auto
            ]
        ]
        
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        guard let videoInput else {
            LOG("Could not set up video input", level: .error)
            return false
        }
        videoInput.expectsMediaDataInRealTime = true
        // Removed line: videoInput.mediaTimeScale = FRAGMENT_TIMESCALE
        
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AUDIO_SAMPLE_RATE,
            AVNumberOfChannelsKey: selectedAudioChannels,
            AVEncoderBitRatePerChannelKey: selectedAudioBitrate,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Variable
        ]
        
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        guard let audioInput else {
            LOG("Could not set up audio input", level: .error)
            return false
        }
        audioInput.expectsMediaDataInRealTime = true
        
        guard fragmentAssetWriter.canAdd(videoInput), fragmentAssetWriter.canAdd(audioInput) else {
            LOG("Could not add the configured media inputs to the asset writer", level: .error)
            return false
        }
        fragmentAssetWriter.add(videoInput)
        fragmentAssetWriter.add(audioInput)
        
        guard fragmentAssetWriter.startWriting() else {
            LOG("Error starting writing: \(fragmentAssetWriter.error?.localizedDescription ?? "Unknown error")", level: .error)
            return false
        }
        
        hasStartedSession = false
        baseVideoPTS = nil
        startupAudio.removeAll()
        pendingAudio.removeAll()
        pendingVideo.removeAll()
        pendingTrimmedAudioSamples = 0
        pendingTrimmedVideoSamples = 0
        startupTrimmedAudioSamples = 0
        lastTrimLogTime = nil
        
        // Freeze sink selection for the lifetime of this writer session so a
        // settings edit cannot split recording and delivery decisions.
        self.stream = stream
        self.record = record
        return true
    }
    
    func finishWriting(deadline: ContinuousClock.Instant) async throws {
        guard let fragmentAssetWriter else {
            throw ContentPackagingError.writerFinishFailed("The asset writer is not active")
        }
        guard hasStartedSession else {
            fragmentAssetWriter.cancelWriting()
            cleanupAfterFinishing()
            throw ContentPackagingError.videoNeverStarted
        }
        try await drainPendingBuffersBeforeFinishing(deadline: deadline)
        if let terminalError {
            fragmentAssetWriter.cancelWriting()
            cleanupAfterFinishing()
            throw terminalError
        }
        // Give already-enqueued segment delegate work one executor turn before
        // callbacks produced by finishWriting are classified as finalization.
        await Task.yield()
        finalizing = true
        nonisolated(unsafe) let sendableAssetWriter = fragmentAssetWriter
        let finishResult = await withCheckedContinuation { continuation in
            let finishContinuation = AssetWriterFinishContinuation(continuation)
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            let remaining = max(.zero, ContinuousClock().now.duration(to: deadline))
            let timeoutTask = Task.detached(priority: .userInitiated) {
                do {
                    try await Task.sleep(for: remaining)
                } catch {
                    return
                }
                sendableAssetWriter.cancelWriting()
                finishContinuation.resume(
                    status: .cancelled,
                    message: "Asset writer did not finish before the shutdown deadline"
                )
            }
            fragmentAssetWriter.finishWriting {
                timeoutTask.cancel()
                finishContinuation.resume(
                    status: sendableAssetWriter.status,
                    message: sendableAssetWriter.error?.localizedDescription
                )
            }
        }
        cleanupAfterFinishing()
        guard finishResult.0 == .completed else {
            throw ContentPackagingError.writerFinishFailed(finishResult.1 ?? "Unknown writer failure")
        }
        LOG("Finished writing successfully", level: .debug)
    }

    private func cleanupAfterFinishing() {
        fragmentAssetWriter = nil
        videoInput = nil
        audioInput = nil
        startupAudio.removeAll(keepingCapacity: false)
        pendingAudio.removeAll(keepingCapacity: false)
        pendingVideo.removeAll(keepingCapacity: false)
        hasStartedSession = false
        baseVideoPTS = nil
    }
    
    // this can be used to ensure that tampering with the contents of the sample buffer has not affected HDR
    func analyzeVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            var formatName = "Unknown"
            
            switch format {
            case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: formatName = "422YpCbCr10BiPlanarVideoRange (x422)"
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: formatName = "420YpCbCr10BiPlanarVideoRange (x420)"
            case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange: formatName = "422YpCbCr10BiPlanarFullRange (xf22)"
            case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: formatName = "420YpCbCr10BiPlanarFullRange (xf20)"
            default: formatName = String(format: "0x%08x", format)
            }
            
            var isHDR = false
            if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
               let attachments = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any] {
                // Check for HDR metadata
                if let colorPrimaries = attachments[kCVImageBufferColorPrimariesKey as String] as? String,
                   let transferFunction = attachments[kCVImageBufferTransferFunctionKey as String] as? String,
                   let yCbCrMatrix = attachments[kCVImageBufferYCbCrMatrixKey as String] as? String {
                    
                    isHDR = (colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String) &&
                    (transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) &&
                    (yCbCrMatrix == AVVideoYCbCrMatrix_ITU_R_2020 as String)
                }
            }
            LOG("Video format of first frame: \(formatName), HDR: \(isHDR)", level: .info)
        }
    }
    
    private func presentationTimestamp(of sampleBuffer: CMSampleBuffer) -> CMTime {
        CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    }

    private func enqueuePendingSample(_ sampleBuffer: CMSampleBuffer, mediaType: MediaType) {
        switch mediaType {
        case .audio:
            pendingAudio.append(sampleBuffer)
        case .video:
            pendingVideo.append(sampleBuffer)
        }
        trimPendingBuffersIfNeeded()
    }

    private func pendingDuration() -> CMTime? {
        let headPTS = [pendingAudio.first, pendingVideo.first]
            .compactMap { $0.map(presentationTimestamp(of:)) }
            .min { CMTimeCompare($0, $1) < 0 }
        let tailPTS = [pendingAudio.last, pendingVideo.last]
            .compactMap { $0.map(presentationTimestamp(of:)) }
            .max { CMTimeCompare($0, $1) < 0 }

        guard let headPTS, let tailPTS else {
            return nil
        }
        return CMTimeSubtract(tailPTS, headPTS)
    }

    private func trimPendingBuffersIfNeeded() {
        let maxPendingDuration = CMTime(seconds: 0.5, preferredTimescale: writerTimeScale)
        let dropSlice = CMTime(seconds: 0.1, preferredTimescale: writerTimeScale)

        while let duration = pendingDuration(), CMTimeCompare(duration, maxPendingDuration) > 0 {
            let oldestPTS = [pendingAudio.first, pendingVideo.first]
                .compactMap { $0.map(presentationTimestamp(of:)) }
                .min { CMTimeCompare($0, $1) < 0 }
            guard let oldestPTS else {
                return
            }

            let cutoffPTS = CMTimeAdd(oldestPTS, dropSlice)
            var droppedAudio = 0
            while let firstAudio = pendingAudio.first,
                  CMTimeCompare(presentationTimestamp(of: firstAudio), cutoffPTS) <= 0 {
                pendingAudio.removeFirst()
                droppedAudio += 1
            }

            var droppedVideo = 0
            while let firstVideo = pendingVideo.first,
                  CMTimeCompare(presentationTimestamp(of: firstVideo), cutoffPTS) <= 0 {
                pendingVideo.removeFirst()
                droppedVideo += 1
            }

            recordTrimmedSamples(audio: droppedAudio, video: droppedVideo)
        }
    }

    private func recordTrimmedSamples(audio: Int, video: Int) {
        pendingTrimmedAudioSamples += audio
        pendingTrimmedVideoSamples += video

        let now = Date()
        if let lastTrimLogTime, now.timeIntervalSince(lastTrimLogTime) < trimLogInterval {
            return
        }

        LOG("Trimmed buffered media due to packager backpressure: dropped \(pendingTrimmedAudioSamples) audio and \(pendingTrimmedVideoSamples) video samples in the last \(Int(trimLogInterval))s", level: .warning)
        pendingTrimmedAudioSamples = 0
        pendingTrimmedVideoSamples = 0
        lastTrimLogTime = now
    }

    private func appendPendingSample(from mediaType: MediaType) -> Bool {
        let input: AVAssetWriterInput?
        let sampleBuffer: CMSampleBuffer?

        switch mediaType {
        case .audio:
            input = audioInput
            sampleBuffer = pendingAudio.first
        case .video:
            input = videoInput
            sampleBuffer = pendingVideo.first
        }

        guard let input, input.isReadyForMoreMediaData, let sampleBuffer else {
            return false
        }
        guard input.append(sampleBuffer) else {
            let writerMessage = fragmentAssetWriter?.error?.localizedDescription ?? "The encoder rejected the sample"
            terminalError = .writerAppendFailed("\(mediaType): \(writerMessage)")
            LOG("Failed to append pending \(mediaType) sample buffer: \(writerMessage)", level: .error)
            return false
        }

        switch mediaType {
        case .audio:
            pendingAudio.removeFirst()
        case .video:
            pendingVideo.removeFirst()
        }
        return true
    }

    @discardableResult
    private func drainPendingBuffers() -> Int {
        var appendedCount = 0
        while true {
            let nextAudioPTS = pendingAudio.first.map(presentationTimestamp(of:))
            let nextVideoPTS = pendingVideo.first.map(presentationTimestamp(of:))

            let preferredType: MediaType?
            switch (nextAudioPTS, nextVideoPTS) {
            case (.none, .none):
                return appendedCount
            case (.some, .none):
                preferredType = .audio
            case (.none, .some):
                preferredType = .video
            case let (.some(audioPTS), .some(videoPTS)):
                preferredType = CMTimeCompare(audioPTS, videoPTS) <= 0 ? .audio : .video
            }

            guard let preferredType else {
                return appendedCount
            }
            if appendPendingSample(from: preferredType) {
                appendedCount += 1
                continue
            }

            let alternateType: MediaType = preferredType == .audio ? .video : .audio
            if appendPendingSample(from: alternateType) {
                appendedCount += 1
                continue
            }
            return appendedCount
        }
    }

    private func drainPendingBuffersBeforeFinishing(
        deadline: ContinuousClock.Instant
    ) async throws {
        let clock = ContinuousClock()
        while (!pendingAudio.isEmpty || !pendingVideo.isEmpty),
              fragmentAssetWriter?.status == .writing,
              clock.now < deadline,
              terminalError == nil {
            let appendedCount = drainPendingBuffers()
            if !pendingAudio.isEmpty || !pendingVideo.isEmpty {
                // AVAssetWriter applies backpressure while it finishes encoding
                // prior samples. Yield until an input is ready rather than
                // marking it finished and silently dropping this tail.
                if appendedCount == 0 {
                    try? await Task.sleep(for: .milliseconds(5))
                } else {
                    await Task.yield()
                }
            }
        }

        if let terminalError {
            throw terminalError
        }
        if !pendingAudio.isEmpty || !pendingVideo.isEmpty {
            throw ContentPackagingError.finalMediaDrainTimedOut(
                audioSamples: pendingAudio.count,
                videoSamples: pendingVideo.count
            )
        }
    }
    
    private func makeSampleBuffer(withNormalizedPTS sampleBuffer: CMSampleBuffer,
                                  basePTS: CMTime,
                                  timeScale: CMTimeScale) -> CMSampleBuffer? {
        var timingCount: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer,
                                                     entryCount: 0,
                                                     arrayToFill: nil,
                                                     entriesNeededOut: &timingCount) == noErr,
              timingCount > 0 else { return nil }

        var timingInfo = Array(repeating: CMSampleTimingInfo(duration: .invalid,
                                                             presentationTimeStamp: .invalid,
                                                             decodeTimeStamp: .invalid),
                               count: timingCount)
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer,
                                                     entryCount: timingCount,
                                                     arrayToFill: &timingInfo,
                                                     entriesNeededOut: &timingCount) == noErr else {
            return nil
        }

        for i in 0..<timingInfo.count {
            let pts = timingInfo[i].presentationTimeStamp
            let dts = timingInfo[i].decodeTimeStamp

            var newPTS = CMTimeSubtract(pts, basePTS)
            var newDTS = dts.isValid ? CMTimeSubtract(dts, basePTS) : .invalid

            newPTS = CMTimeConvertScale(newPTS, timescale: timeScale, method: .roundHalfAwayFromZero)
            if newDTS.isValid {
                newDTS = CMTimeConvertScale(newDTS, timescale: timeScale, method: .roundHalfAwayFromZero)
            }

            timingInfo[i].presentationTimeStamp = newPTS
            timingInfo[i].decodeTimeStamp = newDTS
        }

        var normalizedBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                           sampleBuffer: sampleBuffer,
                                                           sampleTimingEntryCount: timingInfo.count,
                                                           sampleTimingArray: &timingInfo,
                                                           sampleBufferOut: &normalizedBuffer)
        return status == noErr ? normalizedBuffer : nil
    }
        
    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) async throws {
        if let terminalError { throw terminalError }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if baseVideoPTS == nil {
            baseVideoPTS = pts
            fragmentAssetWriter?.startSession(atSourceTime: .zero)
            hasStartedSession = true
            LOG("Asset writing started at .zero; baseVideoPTS: \(pts.value)/\(pts.timescale)", level: .debug)
            // Flush any pending audio that normalizes to >= .zero
            if !startupAudio.isEmpty, let basePTS = baseVideoPTS {
                for audioBuf in startupAudio {
                    if let normalized = makeSampleBuffer(withNormalizedPTS: audioBuf, basePTS: basePTS, timeScale: writerTimeScale) {
                        let firstPTS = CMSampleBufferGetPresentationTimeStamp(normalized)
                        if CMTimeCompare(firstPTS, .zero) >= 0 {
                            enqueuePendingSample(normalized, mediaType: .audio)
                        }
                    }
                }
                startupAudio.removeAll()
            }
        }

        if let basePTS = baseVideoPTS,
           let normalized = makeSampleBuffer(withNormalizedPTS: sampleBuffer, basePTS: basePTS, timeScale: writerTimeScale) {
            enqueuePendingSample(normalized, mediaType: .video)
        } else {
            enqueuePendingSample(sampleBuffer, mediaType: .video)
        }
        drainPendingBuffers()
        if let terminalError { throw terminalError }
    }
    
    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) async throws {
        if let terminalError { throw terminalError }
        // Buffer audio until the video session has started to ensure aligned timelines
        guard hasStartedSession, let basePTS = baseVideoPTS else {
            startupAudio.append(sampleBuffer)
            trimStartupAudioIfNeeded()
            return
        }

        if let normalized = makeSampleBuffer(withNormalizedPTS: sampleBuffer, basePTS: basePTS, timeScale: writerTimeScale) {
            enqueuePendingSample(normalized, mediaType: .audio)
        } else {
            enqueuePendingSample(sampleBuffer, mediaType: .audio)
        }
        drainPendingBuffers()
        if let terminalError { throw terminalError }
    }

    private func trimStartupAudioIfNeeded() {
        let maximumDuration = CMTime(seconds: 1, preferredTimescale: writerTimeScale)
        while let first = startupAudio.first, let last = startupAudio.last,
              CMTimeCompare(
                CMTimeSubtract(presentationTimestamp(of: last), presentationTimestamp(of: first)),
                maximumDuration
              ) > 0 {
            startupAudio.removeFirst()
            startupTrimmedAudioSamples += 1
        }
        if startupTrimmedAudioSamples == 1 || startupTrimmedAudioSamples % 100 == 0 {
            LOG(
                "Video has not started; trimmed \(startupTrimmedAudioSamples) old startup audio samples to keep memory bounded",
                level: .warning
            )
        }
    }

    func status() -> AVAssetWriter.Status? {
        fragmentAssetWriter?.status
    }

    func shouldStream() -> Bool {
        stream
    }
    
    func shouldRecord() -> Bool {
        record
    }
    
    func isFinalizing() -> Bool {
        finalizing
    }
}

final class FragmentSequenceNumber: @unchecked Sendable {
    // with next() first sequence is numbered 0 (ensuring correspondence with the sequence numbers in the m4s files)
    private var fragmentSequenceNumber: Int = -1
    private let lock = NSLock()
    func next() -> Int {
        lock.withLock {
            fragmentSequenceNumber += 1
            return fragmentSequenceNumber
        }
    }
    func last() -> Int {
        lock.withLock { fragmentSequenceNumber }
    }
    func reset() {
        lock.withLock { fragmentSequenceNumber = -1 }
    }
}

enum RecordingError: LocalizedError, Equatable {
    case folderUnavailable
    case missingInitialization
    case createFailed(String)
    case writeFailed(sequence: Int, message: String)
    case finalizeFailed(String)

    var errorDescription: String? {
        switch self {
        case .folderUnavailable:
            "The local recording folder is unavailable"
        case .missingInitialization:
            "The local recording did not receive an initialization fragment"
        case .createFailed(let message):
            "Could not create the local recording: \(message)"
        case .writeFailed(let sequence, let message):
            "Could not write recording fragment \(sequence): \(message)"
        case .finalizeFailed(let message):
            "Could not finalize the local recording: \(message)"
        }
    }
}

protocol RecordingFileWriting: Sendable {
    func write(_ data: Data) throws
    func synchronize() throws
    func close() throws
}

protocol RecordingFileCreating: Sendable {
    func createFile(at url: URL) throws -> any RecordingFileWriting
}

struct SystemRecordingFileFactory: RecordingFileCreating {
    func createFile(at url: URL) throws -> any RecordingFileWriting {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        ) else {
            throw RecordingError.createFailed("The file could not be created")
        }
        return SystemRecordingFile(handle: try FileHandle(forWritingTo: url))
    }
}

private final class SystemRecordingFile: RecordingFileWriting, @unchecked Sendable {
    private var handle: FileHandle?

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        guard let handle else {
            throw CocoaError(.fileNoSuchFile)
        }
        try handle.write(contentsOf: data)
    }

    func synchronize() throws {
        try handle?.synchronize()
    }

    func close() throws {
        try handle?.close()
        handle = nil
    }

    deinit {
        try? handle?.close()
    }
}

actor RecordingActor {
    private var filename: String?
    private var fileURL: URL?
    private var file: (any RecordingFileWriting)?
    private let recordingFolder: URL?
    private let fileFactory: any RecordingFileCreating
    private var prepared = false
    private var sawInitialization = false
    private var closed = true
    private var failure: RecordingError?

    init(
        recordingFolder: URL? = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first,
        fileFactory: any RecordingFileCreating = SystemRecordingFileFactory()
    ) {
        self.recordingFolder = recordingFolder
        self.fileFactory = fileFactory
        if recordingFolder == nil {
            LOG("Could not access directory where fragments are stored", level: .error)
        }
    }

    func prepareForNewSession() {
        try? file?.close()
        filename = nil
        fileURL = nil
        file = nil
        prepared = true
        sawInitialization = false
        closed = false
        failure = nil
    }

    func enqueueFragment(_ fragment: Fragment) {
        guard prepared, failure == nil else {
            return
        }
        do {
            try writeFragment(fragment)
        } catch let recordingError as RecordingError {
            failure = recordingError
            LOG(recordingError.localizedDescription, level: .error)
        } catch {
            let recordingError = RecordingError.writeFailed(
                sequence: fragment.sequence,
                message: error.localizedDescription
            )
            failure = recordingError
            LOG(recordingError.localizedDescription, level: .error)
        }
    }

    func finish() throws {
        guard prepared else {
            return
        }
        defer { prepared = false }
        if let failure {
            try? file?.close()
            file = nil
            closed = true
            throw failure
        }
        guard sawInitialization else {
            closed = true
            throw RecordingError.missingInitialization
        }
        if !closed {
            try finalizeFile()
        }
    }

    func recordingURL() -> URL? {
        fileURL
    }

    private func writeFragment(_ fragment: Fragment) throws {
        if fragment.type == .initialization {
            LOG("Starting recording", level: .debug)
            try openRecording()
            sawInitialization = true
        }
        guard let file else {
            throw RecordingError.missingInitialization
        }
        do {
            try file.write(fragment.segment)
            LOG("Appended fragment \(fragment.sequence) to file: \(filename ?? "<none>")", level: .debug)
        } catch {
            throw RecordingError.writeFailed(
                sequence: fragment.sequence,
                message: error.localizedDescription
            )
        }
    }

    private func openRecording() throws {
        guard let recordingFolder else {
            throw RecordingError.folderUnavailable
        }
        let filename = "recording_\(HLSMediaPlaylist.makeSessionIdentifier()).mp4"
        self.filename = filename
        let fileURL = recordingFolder.appendingPathComponent(filename)
        self.fileURL = fileURL
        do {
            file = try fileFactory.createFile(at: fileURL)
        } catch let error as RecordingError {
            file = nil
            throw error
        } catch {
            file = nil
            throw RecordingError.createFailed(error.localizedDescription)
        }
    }

    private func finalizeFile() throws {
        guard let file else {
            if closed { return }
            throw RecordingError.finalizeFailed("The recording file is not open")
        }
        do {
            try file.synchronize()
            try file.close()
            self.file = nil
            closed = true
        } catch {
            throw RecordingError.finalizeFailed(error.localizedDescription)
        }
    }

    deinit {
        try? file?.close()
    }
}

actor OrderedFragmentDispatcher {
    private var pending: [Int: Fragment] = [:]
    private var nextExpectedSequence = 0
    private var streams = false
    private var records = false

    func prepare(stream: Bool, record: Bool) {
        pending.removeAll(keepingCapacity: true)
        nextExpectedSequence = 0
        streams = stream
        records = record
    }

    func enqueue(_ fragment: Fragment, recording: RecordingActor) async {
        pending[fragment.sequence] = fragment
        while let next = pending.removeValue(forKey: nextExpectedSequence) {
            nextExpectedSequence += 1
            if streams {
                await EncodedOutputRouter.shared.route(next)
            }
            if records {
                await recording.enqueueFragment(next)
            }
        }
    }

    func finish() throws {
        guard pending.isEmpty else {
            throw ContentPackagingError.fragmentSequenceGap(
                expected: nextExpectedSequence,
                pending: pending.keys.sorted()
            )
        }
    }
}

final class ContentPackager: NSObject, AVAssetWriterDelegate, Sendable {
    @PipelineActor public static let shared = ContentPackager()
    @PipelineActor private static let assetWriter = AssetWriterActor()
    private let fragmentSequenceNumber = FragmentSequenceNumber()
    private let recording = RecordingActor()
    private let fragmentDispatcher = OrderedFragmentDispatcher()
    private let fragmentDispatchGroup = DispatchGroup()

    func isPackaging() async -> Bool {
        await ContentPackager.assetWriter.status() == .writing
    }

    func beginPackaging(stream: Bool, record: Bool) async throws {
        guard await ContentPackager.assetWriter.status() != .writing else {
            throw ContentPackagingError.assetWriterAlreadyWriting
        }
        self.fragmentSequenceNumber.reset()
        await fragmentDispatcher.prepare(stream: stream, record: record)
        guard await ContentPackager.assetWriter.setupFragmentAssetWriter(
            stream: stream,
            record: record
        ) else {
            throw ContentPackagingError.assetWriterSetupFailed
        }
        if record {
            await recording.prepareForNewSession()
        }
        LOG("Asset writer is now intercepting sample buffers", level: .debug)
    }
    func endPackaging(
        deadline requestedDeadline: ContinuousClock.Instant? = nil
    ) async throws -> ContentPackagingShutdownReport {
        let clock = ContinuousClock()
        let deadline = requestedDeadline ?? clock.now.advanced(by: .seconds(10))
        let shouldRecord = await ContentPackager.assetWriter.shouldRecord()
        let writerWasPrepared = await ContentPackager.assetWriter.status() != nil
        var writerStatus: ShutdownComponentStatus = writerWasPrepared ? .completed : .notRequested
        var dispatchStatus: ShutdownComponentStatus = writerWasPrepared ? .completed : .notRequested
        var recordingStatus: ShutdownComponentStatus = shouldRecord ? .completed : .notRequested
        if writerWasPrepared {
            do {
                try await ContentPackager.assetWriter.finishWriting(deadline: deadline)
            } catch {
                writerStatus = .failed(error.localizedDescription)
            }
            if await waitForFragmentDispatch(deadline: deadline) {
                do {
                    try await fragmentDispatcher.finish()
                } catch {
                    dispatchStatus = .failed(error.localizedDescription)
                }
            } else {
                dispatchStatus = .failed("Fragment delivery did not finish before the shutdown deadline")
            }
        } else {
            LOG("Asset writer had already stopped intercepting sample buffers", level: .debug)
        }
        if shouldRecord {
            if dispatchStatus.failedMessage == nil, clock.now < deadline {
                do {
                    try await recording.finish()
                    if clock.now >= deadline {
                        recordingStatus = .failed("Recording finalization exceeded the shutdown deadline")
                    }
                } catch {
                    recordingStatus = .failed(error.localizedDescription)
                }
            } else {
                recordingStatus = .failed("Recording could not finalize before the shutdown deadline")
            }
        }
        LOG("Asset writer is no longer intercepting sample buffers", level: .debug)
        let report = ContentPackagingShutdownReport(
            assetWriter: writerStatus,
            fragmentDispatch: dispatchStatus,
            recording: recordingStatus
        )
        if !report.succeeded {
            throw ContentPackagingShutdownError(report: report)
        }
        return report
    }

    private func waitForFragmentDispatch(
        deadline: ContinuousClock.Instant
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let oneShot = OneShotBoolContinuation(continuation)
            let remaining = max(.zero, ContinuousClock().now.duration(to: deadline))
            let timeoutTask = Task.detached(priority: .userInitiated) {
                do {
                    try await Task.sleep(for: remaining)
                } catch {
                    return
                }
                oneShot.resume(returning: false)
            }
            fragmentDispatchGroup.notify(queue: .global(qos: .userInitiated)) {
                timeoutTask.cancel()
                oneShot.resume(returning: true)
            }
        }
    }
    
    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) async throws {
        nonisolated(unsafe) let sendableSampleBuffer = sampleBuffer
        try await ContentPackager.assetWriter.appendVideoSampleBuffer(sendableSampleBuffer)
    }
    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) async throws {
        nonisolated(unsafe) let sendableSampleBuffer = sampleBuffer
        try await ContentPackager.assetWriter.appendAudioSampleBuffer(sendableSampleBuffer)
    }
    func assetWriter(_ writer: AVAssetWriter,
                     didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        let sequenceNumber = fragmentSequenceNumber.next()
        fragmentDispatchGroup.enter()
        Task { @PipelineActor in
            defer { self.fragmentDispatchGroup.leave() }
            guard let fragmentType: Fragment.SegmentType = {
                switch (segmentType, ContentPackager.assetWriter.isFinalizing()) {
                case (.separable, false): .separable
                case (.initialization, _): .initialization
                case (.separable, true): .finalization
                @unknown default: nil
                }
            }() else {
                LOG("Unknown segment type", level: .error)
                return
            }
            let duration = segmentReport?.trackReports.first?.duration.seconds ?? 0
            let fragment = Fragment(sequence: sequenceNumber, segment: segmentData, duration: duration, type: fragmentType)
            LOG("Produced \(fragment)", level: .debug)

#if DEBUG
            await FMP4FixtureCapture.shared.capture(fragment)
#endif
            
            await fragmentDispatcher.enqueue(fragment, recording: recording)
        }
    }
}

enum ContentPackagingError: LocalizedError {
    case assetWriterAlreadyWriting
    case assetWriterSetupFailed
    case videoNeverStarted
    case writerAppendFailed(String)
    case writerFinishFailed(String)
    case finalMediaDrainTimedOut(audioSamples: Int, videoSamples: Int)
    case fragmentSequenceGap(expected: Int, pending: [Int])

    var errorDescription: String? {
        switch self {
        case .assetWriterAlreadyWriting:
            "The HEVC/AAC asset writer is already running"
        case .assetWriterSetupFailed:
            "Could not start the HEVC/AAC asset writer"
        case .videoNeverStarted:
            "The stream produced no video frames"
        case .writerAppendFailed(let message):
            "The HEVC/AAC writer stopped accepting media: \(message)"
        case .writerFinishFailed(let message):
            "The HEVC/AAC writer could not finish: \(message)"
        case .finalMediaDrainTimedOut(let audioSamples, let videoSamples):
            "The HEVC/AAC writer could not drain \(videoSamples) video and \(audioSamples) audio samples before shutdown"
        case .fragmentSequenceGap(let expected, let pending):
            "Encoded fragment ordering stopped at \(expected); pending fragments: \(pending)"
        }
    }
}
