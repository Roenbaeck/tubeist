import AVFoundation
import Foundation

@main struct ResilienceProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Usage: resilience-probe <directory> <scenario>") }
        try await run(folder: URL(fileURLWithPath: CommandLine.arguments[1]), scenario: CommandLine.arguments[2])
    }

    @PipelineActor static func run(folder: URL, scenario: String) async throws {
        if scenario == "watchdog" { try await checkWatchdog(); return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clock = ProbeClock()
        let audioPool = scenario.hasPrefix("audio-pool") ? ProbeAudioCapturePool() : nil
        let transport = ProbeTransport(folder: folder, blocked: scenario == "network-overflow")
        let sink = YouTubeHLSStreamSink()
        try await sink.prepare(endpoint: .manualPrimary(streamKey: "offline-probe"),
                               sessionIdentifier: "probe", userAgent: "Tubeist/Probe", transport: transport, sleeper: { _ in })
        let collector = RecordingCollector()
        let recording = try RecordingAssetWriter(delegate: collector, finalizationFlag: AssetWriterFinalizationFlag())
        let pipeline = LiveEncodingPipeline(now: { clock.read() }, automaticWatchdog: false,
                                            publish: { await sink.enqueue($0) })
        var preset = Preset()
        if scenario == "mono-recovery" { preset.audioChannels = 1 }
        try pipeline.start(preset: preset, stream: true, recording: recording)
        let rate = 48_000.0
        let duration = scenario == "stop-boundary" ? 6 + 1.0 / 30
            : scenario == "network-overflow" ? 70.4 : scenario == "stabilization-changes" ? 33.4 : scenario == "long-recovery" ? 34.4 : 10.4
        let totalFrames = Int(duration * 30)
        var audioOffset = 0
        var recoveryObserved = false
        var deliveredVideoFrames = 0

        func captureTime(_ time: Double, video: Bool = false) -> Double {
            if scenario == "startup-audio-overlap" { return 100 + time + (video ? 0.005 : 0) }
            if scenario == "clock-reset", time >= 3 { return 10 + time - 3 }
            // Stabilization changes delivery latency, not the common capture clock.
            let videoDelay = scenario == "stabilization-changes" && video
                ? (time >= 24 ? 0.6 : time >= 15 ? 1.2 : 0.0) : 0.0
            return 100 + time - videoDelay
        }
        func missing(_ time: Double, video: Bool) -> Bool {
            // Stop freezes the microphone before the last stabilized camera
            // frames drain, occasionally leaving a new keyframe without audio.
            if scenario == "stop-boundary" { return !video && time >= 5.85 }
            // Model a latest-frame mailbox under sustained processing pressure:
            // real frames still arrive regularly, but intermediate PTS values
            // have been coalesced. They must not trigger duplicate catch-up.
            if scenario == "processing-pressure" {
                return video && !Int((time * 30).rounded()).isMultiple(of: 3)
            }
            if scenario == "long-recovery" { return (3..<30).contains(time) }
            if scenario == "short-gaps" { return time >= 2 && time < 2.2 }
            if scenario == "audio-pool-startup" { return video && time < 2.5 }
            if scenario == "audio-pool-recovery" { return video && (3..<8).contains(time) }
            if scenario == "stabilization-changes" {
                return video && ((3..<6).contains(time) || (12..<15).contains(time) || (21..<24).contains(time))
            }
            guard time >= 3 && time < 6 else { return false }
            return ["both-stall", "mono-recovery"].contains(scenario) || scenario == (video ? "video-stall" : "audio-stall")
        }

        for frame in 0..<totalFrames {
            let time = Double(frame) / 30
            clock.set(time)
            while Double(audioOffset) / rate <= time {
                let audioTime = Double(audioOffset) / rate
                if !missing(audioTime, video: false) {
                    let sample = try ProbeMediaFixtures.makeAudio(offset: audioOffset, frames: 1024, rate: rate)
                    let timed = try retime(sample, to: captureTime(audioTime))
                    if let audioPool {
                        if let captured = try audioPool.capture(timed) { try await pipeline.appendAudio(captured) }
                    } else { try await pipeline.appendAudio(timed) }
                    if scenario == "short-gaps", frame == 90 {
                        try await pipeline.appendAudio(timed) // exact duplicate
                        try await pipeline.appendAudio(retime(sample, to: captureTime(audioTime - 0.1)))
                    }
                }
                audioOffset += 1024
            }
            if !missing(time, video: true) {
                deliveredVideoFrames += 1
                let sample = try videoSample(frame: frame, pts: captureTime(time, video: true))
                try await pipeline.appendVideo(sample)
                if scenario == "short-gaps", frame == 90 {
                    try await pipeline.appendVideo(sample)
                    try await pipeline.appendVideo(videoSample(frame: frame - 3, pts: captureTime(time - 0.1)))
                }
            }
            if frame.isMultiple(of: 3) { try await pipeline.checkCapture() }
            if pipeline.captureState == .recovering { recoveryObserved = true }
            if scenario == "stabilization-changes", [9 * 30, 18 * 30, 27 * 30].contains(frame) {
                guard pipeline.captureState == .healthy else {
                    throw MediaEncodingError.invalid("Capture did not recover after stabilization change at \(time)s")
                }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        if let audioPool {
            guard audioPool.exhaustionCount == 0, pipeline.captureState == .healthy else {
                throw MediaEncodingError.invalid("Audio capture storage exhausted \(audioPool.exhaustionCount) times; state \(String(describing: pipeline.captureState))")
            }
        }
        if scenario == "stop-boundary" { pipeline.beginFinalization() }
        try await pipeline.finish(deadline: ContinuousClock().now.advanced(by: .seconds(20)))
        if let audioPool {
            precondition(audioPool.retainedBuffers == 0, "Capture storage was retained after shutdown")
        }
        await transport.release()
        try await sink.finish(timeout: 20)
        try collector.save(to: folder.appendingPathComponent("recording.mp4"))
        let metrics = await sink.metrics()
        if ["both-stall", "mono-recovery", "long-recovery", "audio-stall", "video-stall", "clock-reset", "stabilization-changes"].contains(scenario) {
            precondition(recoveryObserved, "Did not exercise coordinated capture recovery")
        }
        if scenario == "network-overflow" {
            precondition(metrics.droppedFragments > 0)
            let uploaded = await transport.uploaded
            precondition(uploaded < 10, "Recovery retained excessive live latency")
        }
        let metadata: [String: Any] = ["scenario": scenario, "inputVideoFrames": totalFrames,
            "deliveredVideoFrames": deliveredVideoFrames,
            "droppedSegments": metrics.droppedFragments, "captureRecovery": recoveryObserved]
        try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appendingPathComponent("result.json"))
        print("PASS: \(scenario), recording finalized, \(metrics.droppedFragments) discarded network segments")
    }

    @PipelineActor static func checkWatchdog() async throws {
        let clock = ProbeClock()
        let failures = ProbeFailures()
        let pipeline = LiveEncodingPipeline(now: { clock.read() },
                                            reportFailure: { await failures.record($0) })
        try pipeline.start(preset: Preset(), stream: false, recording: nil)
        try await pipeline.appendVideo(videoSample(frame: 0, pts: 100))
        try await pipeline.appendAudio(retime(ProbeMediaFixtures.makeAudio(offset: 0, frames: 1024, rate: 48_000), to: 100))
        clock.set(3)
        try await Task.sleep(for: .milliseconds(250))
        precondition(pipeline.captureState == .recovering, "Independent timer failed to detect a silent stall")
        clock.set(3.1)
        for frame in 0..<2 {
            try await pipeline.appendVideo(videoSample(frame: frame, pts: 200 + Double(frame) / 30))
            try await pipeline.appendAudio(retime(ProbeMediaFixtures.makeAudio(offset: frame * 1024, frames: 1024, rate: 48_000),
                                                 to: 200 + Double(frame * 1024) / 48_000))
        }
        precondition(pipeline.captureState == .healthy, "Capture did not recover")
        clock.set(40)
        try await Task.sleep(for: .milliseconds(250))
        let reported = await failures.count
        precondition(reported == 1, "Watchdog stopped across an encoder restart or reported a failure repeatedly")
        try await pipeline.finish(deadline: ContinuousClock().now.advanced(by: .seconds(5)))
        // A previous session's timer must not fail or modify the next session.
        try pipeline.start(preset: Preset(), stream: false, recording: nil)
        try await pipeline.appendVideo(videoSample(frame: 0, pts: 300))
        try await pipeline.appendAudio(retime(ProbeMediaFixtures.makeAudio(offset: 0, frames: 1024, rate: 48_000), to: 300))
        try await Task.sleep(for: .milliseconds(250))
        let finalReports = await failures.count
        precondition(finalReports == 1 && pipeline.captureState == .healthy)
        pipeline.beginFinalization()
        clock.set(80)
        try await pipeline.checkCapture()
        try await Task.sleep(for: .milliseconds(250))
        let stoppingReports = await failures.count
        precondition(stoppingReports == 1 && pipeline.captureState == nil,
                     "Intentional capture shutdown triggered the watchdog")
        try await pipeline.finish(deadline: ContinuousClock().now.advanced(by: .seconds(5)))
        print("PASS: automatic watchdog detects total silence, survives recovery and is cancelled between sessions")
    }

    static func videoSample(frame: Int, pts: Double) throws -> CMSampleBuffer {
        let pixels = try ProbeMediaFixtures.makePixels(frame: frame)
        var format: CMVideoFormatDescription?
        try checkMediaStatus(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels,
                                                                         formatDescriptionOut: &format), "Video format")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90_000), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        try checkMediaStatus(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels,
            formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &buffer), "Video sample")
        return buffer!
    }

    static func retime(_ sample: CMSampleBuffer, to pts: Double) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90_000), decodeTimeStamp: .invalid)
        // For PCM the single timing entry describes one sample, not the block.
        let format = CMSampleBufferGetFormatDescription(sample)!
        let rate = CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee.mSampleRate
        timing.duration = CMTime(value: 1, timescale: Int32(rate))
        var copy: CMSampleBuffer?
        try checkMediaStatus(CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy), "Audio timestamp")
        return copy!
    }
}
