import AVFoundation
import Foundation

// This development executable compiles the production encoders, assembler,
// muxer, and recording writer without the application's capture/UI dependencies.
@globalActor actor PipelineActor: GlobalActor { static let shared = PipelineActor() }

final class RecordingCollector: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var callbacks = 0

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        lock.withLock { bytes.append(data); callbacks += 1 }
    }

    func save(to url: URL) throws {
        try lock.withLock {
            precondition(callbacks > 1, "Recording writer did not produce fragments")
            try bytes.write(to: url)
        }
    }
}

@main struct VideoToolboxProbe {
    static func main() async throws { try await run() }

    @PipelineActor static func run() async throws {
        guard CommandLine.arguments.count >= 2 else { fatalError("Usage: videotoolbox-probe <output-directory>") }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fps = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 30
        let channels = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 2
        let inputRate = CommandLine.arguments.count > 4 ? Double(CommandLine.arguments[4])! : 44_100
        let video = try HEVCVideoEncoder(width: 320, height: 180, frameRate: Double(fps), bitrate: 1_000_000)
        let audio = AACAudioEncoder(channels: channels, bitratePerChannel: 64_000)
        let collector = RecordingCollector()
        let recording = try RecordingAssetWriter(delegate: collector, finalizationFlag: AssetWriterFinalizationFlag())
        var assembler = EncodedSegmentAssembler()
        var muxer = MPEGTransportStreamMuxer()
        var segmentCount = 0
        var videoCount = 0
        var audioCount = 0
        var reordered = 0
        var encodedHashes: [String] = []
        let frameCount = Int(Double(fps) * 12.4)
        let audioFrames = Int(Double(frameCount) / Double(fps) * inputRate)
        var audioOffset = 0

        @PipelineActor func acceptVideo(_ samples: [CMSampleBuffer]) throws {
            for buffer in samples {
                try recording.append(buffer, kind: .video)
                let sample = try EncodedSampleAdapter.sample(buffer, kind: .video, fallbackDuration: video.frameDuration)
                assembler.hevc = try EncodedSampleAdapter.hevcConfiguration(CMSampleBufferGetFormatDescription(buffer)!)
                try assembler.append(sample)
                videoCount += 1
                if sample.decodeTime != sample.presentationTime { reordered += 1 }
                encodedHashes.append("v \(sample.presentationTime) \(sample.data.count)")
            }
        }
        @PipelineActor func acceptAudio(_ samples: [CMSampleBuffer]) throws {
            assembler.aac = audio.configuration
            for buffer in samples {
                try recording.append(buffer, kind: .audio)
                let sample = try EncodedSampleAdapter.sample(buffer, kind: .audio)
                try assembler.append(sample)
                audioCount += 1
            }
        }
        @PipelineActor func emit(finishing: Bool = false) throws {
            for segment in try assembler.takeReadySegments(finishing: finishing) {
                let ts = try muxer.mux(segment)
                precondition(ts.duration <= 2.1 || finishing, "Unexpected segment duration")
                try ts.data.write(to: folder.appendingPathComponent(String(format: "segment_%03d.ts", segmentCount)))
                print("segment \(segmentCount): \(ts.duration)s, \(ts.data.count) bytes")
                segmentCount += 1
            }
        }
        for frame in 0..<frameCount {
            if frame == fps * 4 { try video.setBitrate(300_000) }
            if frame == fps * 8 { try video.setBitrate(700_000) }
            let pts = CMTime(value: Int64(frame), timescale: Int32(fps))
            while audioOffset < audioFrames, Double(audioOffset) / inputRate <= pts.seconds {
                let count = min(1024, audioFrames - audioOffset)
                try acceptAudio(audio.encode(makeAudio(offset: audioOffset, frames: count, rate: inputRate), basePTS: .zero))
                audioOffset += count
            }
            let pixels = try makePixels(frame: frame)
            try video.encode(pixels, presentationTime: pts, forceKeyframe: frame % (fps * 2) == 0)
            try acceptVideo(video.takeOutput())
            try emit()
            // Yield to the hardware and recording writer, without emulating a
            // physical camera or measuring encoder performance.
            try await Task.sleep(for: .milliseconds(5))
        }
        while audioOffset < audioFrames {
            let count = min(1024, audioFrames - audioOffset)
            try acceptAudio(audio.encode(makeAudio(offset: audioOffset, frames: count, rate: inputRate), basePTS: .zero))
            audioOffset += count
        }
        try acceptVideo(video.finish())
        try acceptAudio(audio.finish())
        try emit(finishing: true)
        try await recording.finish(deadline: ContinuousClock().now.advanced(by: .seconds(20)))
        let metadata = try JSONSerialization.data(withJSONObject: ["videoFrames": frameCount, "channels": channels, "primingSeconds": audio.primingDuration] as [String: Any])
        try metadata.write(to: folder.appendingPathComponent("expected.json"))
        try collector.save(to: folder.appendingPathComponent("recording.mp4"))
        try encodedHashes.joined(separator: "\n").write(to: folder.appendingPathComponent("encoded-video.txt"), atomically: true, encoding: .utf8)
        precondition(videoCount == frameCount, "Video frames were lost")
        precondition(reordered > 0, "Reordered timestamp path was not exercised")
        precondition(segmentCount == 7, "Expected six full segments and a complete tail")
        print("PASS: \(videoCount) video frames, \(audioCount) AAC packets, \(segmentCount) TS segments, three live bitrate targets, and passthrough MP4 recording")
    }

    static func makePixels(frame: Int) throws -> CVPixelBuffer {
        var pixels: CVPixelBuffer?
        try checkMediaStatus(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), "Creating test pixels")
        guard let pixels else { fatalError("Missing pixels") }
        CVPixelBufferLockBaseAddress(pixels, [])
        for plane in 0..<2 {
            let pointer = CVPixelBufferGetBaseAddressOfPlane(pixels, plane)!.assumingMemoryBound(to: UInt16.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) / 2
            let height = CVPixelBufferGetHeightOfPlane(pixels, plane)
            for y in 0..<height {
                for x in 0..<320 {
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
        return pixels
    }

    static func makeAudio(offset: Int, frames: Int, rate: Double) throws -> CMSampleBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 {
            for index in 0..<frames {
                let time = Double(offset + index) / rate
                pcm.floatChannelData![channel][index] = time < 0.25 ? 0 : Float(sin(time * 2 * .pi * 1000) * 0.2)
            }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
                                       presentationTimeStamp: CMTime(value: Int64(offset), timescale: Int32(rate)), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        try checkMediaStatus(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &buffer), "Creating test audio")
        try checkMediaStatus(CMSampleBufferSetDataBufferFromAudioBufferList(buffer!, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList), "Copying test audio")
        return buffer!
    }
}
