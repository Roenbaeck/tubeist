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
        // validate_recovery.sh injects failed callbacks into a temporary source
        // copy. The shipping encoder has no fault-injection behavior.
        let injectedFailures = Set((ProcessInfo.processInfo.environment["TUBEIST_PROBE_FAILED_FRAMES"] ?? "")
            .split(separator: ",").compactMap { Int($0) })
        let overshootProbe = ProcessInfo.processInfo.environment["TUBEIST_PROBE_OVERSHOOT"] == "1"
        let regulatesBitrate = ProcessInfo.processInfo.environment["TUBEIST_PROBE_UNREGULATED"] != "1"
        let noiseRange = Int(ProcessInfo.processInfo.environment["TUBEIST_PROBE_NOISE_RANGE"] ?? "129") ?? 129
        let video = try HEVCVideoEncoder(width: 320, height: 180, frameRate: Double(fps), bitrate: 1_000_000, regulatesBitrate: regulatesBitrate)
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
        var encodedFrames: [[String: Double]] = []
        let targetInterval = overshootProbe ? 8 : 4
        let duration = Double(targetInterval * 3) + 0.4
        let frameCount = Int(Double(fps) * duration)
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
                encodedFrames.append(["dts": Double(sample.decodeTime) / Double(sample.timescale),
                                      "pts": Double(sample.presentationTime) / Double(sample.timescale),
                                      "bytes": Double(sample.data.count)])
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
                precondition(ts.duration <= (injectedFailures.isEmpty ? 2.1 : 5) || finishing, "Unexpected segment duration")
                try ts.data.write(to: folder.appendingPathComponent(String(format: "segment_%03d.ts", segmentCount)))
                print("segment \(segmentCount): \(ts.duration)s, \(ts.data.count) bytes")
                segmentCount += 1
            }
        }
        for frame in 0..<frameCount {
            if frame == fps * targetInterval { try video.setBitrate(300_000) }
            if frame == fps * targetInterval * 2 { try video.setBitrate(700_000) }
            let pts = CMTime(value: Int64(frame), timescale: Int32(fps))
            while audioOffset < audioFrames, Double(audioOffset) / inputRate <= pts.seconds {
                let count = min(1024, audioFrames - audioOffset)
                try acceptAudio(audio.encode(ProbeMediaFixtures.makeAudio(offset: audioOffset, frames: count, rate: inputRate), basePTS: .zero))
                audioOffset += count
            }
            let pixels = try ProbeMediaFixtures.makePixels(frame: frame, noisy: overshootProbe, noiseRange: noiseRange)
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
        let metadata = try JSONSerialization.data(withJSONObject: [
            "videoFrames": videoCount, "submittedFrames": frameCount, "channels": channels, "duration": duration,
            "failedFrames": video.failedFrames, "recoveryDiscardedFrames": video.recoveryDiscardedFrames,
            "primingSeconds": audio.primingDuration,
            "overshootProbe": overshootProbe, "regulatesBitrate": regulatesBitrate,
            "bitrateCorrections": video.bitrateCorrections, "appliedBitrate": video.appliedBitrate
        ] as [String: Any])
        try metadata.write(to: folder.appendingPathComponent("expected.json"))
        try JSONSerialization.data(withJSONObject: encodedFrames).write(to: folder.appendingPathComponent("encoded-frames.json"))
        try collector.save(to: folder.appendingPathComponent("recording.mp4"))
        try encodedHashes.joined(separator: "\n").write(to: folder.appendingPathComponent("encoded-video.txt"), atomically: true, encoding: .utf8)
        if injectedFailures.isEmpty {
            precondition(videoCount == frameCount, "Video frames were lost")
            precondition(segmentCount == targetInterval * 3 / 2 + 1, "Expected full segments and a complete tail")
        } else {
            precondition(video.failedFrames == injectedFailures.count, "Did not exercise the requested callback failures")
            precondition(videoCount + video.failedFrames + video.recoveryDiscardedFrames == frameCount,
                         "Recovery lost unaccounted frames")
            precondition(videoCount >= frameCount - injectedFailures.count - fps * 2, "Recovery discarded too much video")
            print("RECOVERY: \(video.failedFrames) failed pictures; \(video.recoveryDiscardedFrames) dependent pictures withheld")
        }
        precondition(reordered > 0, "Reordered timestamp path was not exercised")
        print("PASS: \(videoCount) video frames, \(audioCount) AAC packets, \(segmentCount) TS segments, three live bitrate targets, and passthrough MP4 recording")
    }

}
