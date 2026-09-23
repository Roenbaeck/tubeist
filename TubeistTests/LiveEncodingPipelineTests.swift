import AVFoundation
import Testing
@testable import Tubeist

/// Real VideoToolbox/AAC/AVAssetWriter encoding of generated media. Faults are
/// injected at the output boundaries: a writer that stops accepting media, and
/// YouTube no longer accepting segments.
@PipelineActor
struct LiveEncodingPipelineTests {
    @Test(.enabled(if: PipelineTestMedia.hasHardwareHEVC), arguments: [true, false])
    func fileWriteFailurePreservesOnlyTheHealthyOutput(streams: Bool) async throws {
        let fragments = PublishedFragments()
        let pipeline = LiveEncodingPipeline(now: { 0 }, automaticWatchdog: false,
                                            publish: { await fragments.append($0) }, streamStopped: { false })
        let delegate = PipelineRecordingFile()
        let writer = try RecordingAssetWriter(delegate: delegate, finalizationFlag: AssetWriterFinalizationFlag())
        let recording = RecordingActor(recordingFolder: FileManager.default.temporaryDirectory,
            fileFactory: InjectedRecordingFileFactory(file: InjectedRecordingFile(failure: .write)))
        await recording.prepareForNewSession(fileFailure: writer.fileFailure)
        try pipeline.start(preset: PipelineTestMedia.preset, stream: streams, recording: writer)
        var media = PipelineTestMedia()
        try await media.feed(pipeline, until: 3)
        let before = await fragments.count
        // Fail the actual file-writing layer, not AVAssetWriter.cancel().
        await recording.enqueueFragment(Fragment(sequence: 0, segment: Data("init".utf8), duration: 0, type: .initialization))
        if streams {
            try await media.feed(pipeline, until: 8)
            #expect(await fragments.count >= before + 2)
        } else {
            await #expect(throws: (any Error).self) { try await media.feed(pipeline, until: 4) }
        }
        #expect(pipeline.recordingFailure?.contains("Could not write recording fragment 0") == true)
        try await pipeline.finish(deadline: ContinuousClock().now.advanced(by: .seconds(20)))
        await #expect(throws: RecordingError.self) { try await recording.finish() }
        withExtendedLifetime(delegate) {}
    }

    @Test(.enabled(if: PipelineTestMedia.hasHardwareHEVC))
    func recordingFailureEndsOnlyTheRecordingWhileStreamingContinues() async throws {
        let fragments = PublishedFragments()
        let pipeline = LiveEncodingPipeline(now: { 0 }, automaticWatchdog: false,
                                            publish: { await fragments.append($0) }, streamStopped: { false })
        let file = PipelineRecordingFile()
        let writer = try RecordingAssetWriter(delegate: file, finalizationFlag: AssetWriterFinalizationFlag())
        try pipeline.start(preset: PipelineTestMedia.preset, stream: true, recording: writer)
        var media = PipelineTestMedia()
        try await media.feed(pipeline, until: 3)
        let publishedBeforeFailure = await fragments.count
        #expect(publishedBeforeFailure > 0)
        #expect(pipeline.recordingFailure == nil)

        writer.cancel() // The writer stops accepting media, as after a storage failure.
        try await media.feed(pipeline, until: 8)
        #expect(pipeline.recordingFailure != nil)
        #expect(pipeline.isRecording, "Stop must still finalize the recording file and report its failure")
        #expect(await fragments.count >= publishedBeforeFailure + 2, "Live segments stopped with the recording")
        try await pipeline.finish(deadline: ContinuousClock().now.advanced(by: .seconds(20)))
        #expect(pipeline.recordingFailure != nil)
        #expect(file.bytes > 0)
    }

    @Test(.enabled(if: PipelineTestMedia.hasHardwareHEVC))
    func recordingFailureEndsARecordingOnlySession() async throws {
        let pipeline = LiveEncodingPipeline(now: { 0 }, automaticWatchdog: false, publish: { _ in }, streamStopped: { false })
        let file = PipelineRecordingFile() // AVAssetWriter holds its delegate weakly.
        let writer = try RecordingAssetWriter(delegate: file, finalizationFlag: AssetWriterFinalizationFlag())
        try pipeline.start(preset: PipelineTestMedia.preset, stream: false, recording: writer)
        var media = PipelineTestMedia()
        try await media.feed(pipeline, until: 1)
        writer.cancel()
        await #expect(throws: (any Error).self) { try await media.feed(pipeline, until: 3) }
        #expect(pipeline.recordingFailure != nil)
        try await pipeline.finish(deadline: ContinuousClock().now.advanced(by: .seconds(20)))
        withExtendedLifetime(file) {}
    }

    @Test(.enabled(if: PipelineTestMedia.hasHardwareHEVC))
    func stoppedIngestionEndsLiveSegmentsWhileTheRecordingContinues() async throws {
        let fragments = PublishedFragments()
        let stopped = PipelineTestFlag()
        let pipeline = LiveEncodingPipeline(now: { 0 }, automaticWatchdog: false,
                                            publish: { await fragments.append($0) }, streamStopped: { stopped.value })
        let file = PipelineRecordingFile()
        let writer = try RecordingAssetWriter(delegate: file, finalizationFlag: AssetWriterFinalizationFlag())
        try pipeline.start(preset: PipelineTestMedia.preset, stream: true, recording: writer)
        var media = PipelineTestMedia()
        try await media.feed(pipeline, until: 5)
        let published = await fragments.count
        #expect(published > 0)
        stopped.value = true
        let recordedBeforeStop = file.bytes
        try await media.feed(pipeline, until: 11)
        // At most the segment completing at the next boundary is still published.
        #expect(await fragments.count <= published + 1)
        #expect(file.bytes > recordedBeforeStop, "The recording stopped with the stream")
        try await pipeline.finish(deadline: ContinuousClock().now.advanced(by: .seconds(20)))
        #expect(pipeline.recordingFailure == nil)
    }
}

struct PipelineTestMedia {
    static let preset = Preset(name: "Test", width: 320, height: 180, frameRate: 30, keyframeInterval: 1,
                               audioChannels: 2, audioBitrate: 64_000, videoBitrate: 1_000_000)
    static let hasHardwareHEVC = (try? HEVCVideoEncoder(width: 320, height: 180, frameRate: 30, bitrate: 1_000_000)) != nil
    private static let audioRate = 48_000.0
    private static let captureStart = 100.0
    private var videoFrame = 0
    private var audioFrame = 0

    /// Delivers capture-ordered audio and video, as the grabbers do, until `time`.
    @PipelineActor mutating func feed(_ pipeline: LiveEncodingPipeline, until time: Double) async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.audioRate, channels: 2)!
        while Double(videoFrame) / 30 < time {
            let videoTime = Double(videoFrame) / 30
            while Double(audioFrame) / Self.audioRate <= videoTime {
                let start = audioFrame
                try await pipeline.appendAudio(AACTestAudio.pcm(format, frames: 1024,
                    pts: Self.captureStart + Double(start) / Self.audioRate) { _, frame in
                        Float(0.2 * sin(2 * .pi * 1000 * Double(start + frame) / Self.audioRate))
                    })
                audioFrame += 1024
            }
            try await pipeline.appendVideo(Self.video(frame: videoFrame, pts: Self.captureStart + videoTime))
            videoFrame += 1
        }
    }

    private static func video(frame: Int, pts: Double) throws -> CMSampleBuffer {
        var created: CVPixelBuffer?
        try checkMediaStatus(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created), "Creating test pixels")
        let pixels = try #require(created)
        CVPixelBufferLockBaseAddress(pixels, [])
        for plane in 0..<2 {
            let pointer = CVPixelBufferGetBaseAddressOfPlane(pixels, plane)!.assumingMemoryBound(to: UInt16.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) / 2
            for y in 0..<CVPixelBufferGetHeightOfPlane(pixels, plane) {
                for x in 0..<CVPixelBufferGetWidthOfPlane(pixels, plane) * (plane == 0 ? 1 : 2) {
                    let value = plane == 0 ? 64 + ((x + y + frame * 7) % 877) : 512 + ((x + frame) % 160) - 80
                    pointer[y * stride + x] = UInt16(value << 6)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for (key, value) in [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020)
        ] { CVBufferSetAttachment(pixels, key, value, .shouldPropagate) }
        var format: CMVideoFormatDescription?
        try checkMediaStatus(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels,
                                                                         formatDescriptionOut: &format), "Video format")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try checkMediaStatus(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels,
            formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample), "Video sample")
        return try #require(sample)
    }
}

private actor PublishedFragments {
    private(set) var count = 0
    func append(_ fragment: Fragment) { count += 1 }
}

private final class PipelineTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class PipelineRecordingFile: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var bytes: Int { lock.withLock { count } }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        lock.withLock { count += segmentData.count }
    }
}
