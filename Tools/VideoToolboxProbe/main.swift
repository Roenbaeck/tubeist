import AVFoundation
import Foundation

// This development executable compiles the production encoders, assembler,
// muxer, and recording writer without the application's capture/UI dependencies.
@globalActor actor PipelineActor: GlobalActor { static let shared = PipelineActor() }

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
                try acceptAudio(audio.encode(ProbeMediaFixtures.makeAudio(offset: audioOffset, frames: count, rate: inputRate), basePTS: .zero))
                audioOffset += count
            }
            let pixels = try ProbeMediaFixtures.makePixels(frame: frame)
            try video.encode(pixels, presentationTime: pts, forceKeyframe: frame % (fps * 2) == 0)
            try acceptVideo(video.takeOutput())
            try emit()
            // Yield to the hardware and recording writer, without emulating a
            // physical camera or measuring encoder performance.
            try await Task.sleep(for: .milliseconds(5))
        }
        while audioOffset < audioFrames {
            let count = min(1024, audioFrames - audioOffset)
            try acceptAudio(audio.encode(ProbeMediaFixtures.makeAudio(offset: audioOffset, frames: count, rate: inputRate), basePTS: .zero))
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

}
