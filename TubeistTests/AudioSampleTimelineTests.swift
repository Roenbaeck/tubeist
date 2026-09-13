import CoreMedia
import Testing
@testable import Tubeist

struct AudioSampleTimelineTests {
    @Test func mapsResamplingAndPrimingOntoTheCaptureClock() throws {
        var timeline = AudioSampleTimeline(sourceSampleRate: 48_000)
        try timeline.append(presentationTime: CMTime(seconds: 0.025, preferredTimescale: 90_000), frames: 480)
        let priming = timeline.presentationTime(outputFrame: 0, outputSampleRate: 44_100, leadingInputFrames: 2304)!
        #expect(abs(priming.seconds - (0.025 - 2304.0 / 48_000)) < 1.0 / 90_000)
        try timeline.append(presentationTime: CMTime(seconds: 0.035, preferredTimescale: 90_000), frames: 480)
        let packet = timeline.presentationTime(outputFrame: 441, outputSampleRate: 44_100)!
        #expect(abs(packet.seconds - 0.035) < 1.0 / 90_000)
    }

    @Test func longCaptureFollowsClockDriftWithoutInventingAGap() throws {
        var timeline = AudioSampleTimeline(sourceSampleRate: 48_000)
        // One hour at +100 ppm produces 360ms of drift: enough to expose a
        // counter-only timestamp scheme while each captured block is continuous.
        for block in 0..<3600 {
            let pts = Double(block) * 1.0001
            let captured = CMTime(seconds: pts, preferredTimescale: 90_000)
            try timeline.append(presentationTime: captured, frames: 48_000)
            let output = timeline.presentationTime(outputFrame: Int64(block) * 44_100, outputSampleRate: 44_100)!
            #expect(CMTimeCompare(output, captured) == 0)
        }
    }

    @Test func actualMissingCaptureIsReported() throws {
        var timeline = AudioSampleTimeline(sourceSampleRate: 48_000)
        try timeline.append(presentationTime: .zero, frames: 480)
        #expect(throws: MediaEncodingError.self) {
            try timeline.append(presentationTime: CMTime(seconds: 1, preferredTimescale: 90_000), frames: 480)
        }
    }
}
