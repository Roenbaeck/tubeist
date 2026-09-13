import CoreMedia
import Testing
@testable import Tubeist

struct CaptureContinuityTests {
    @Test func detectsSilentStallsWithoutAnyFurtherSamples() {
        var live = CaptureLiveness(startedAt: 10)
        #expect(live.state(at: 10) == .starting)
        live.receivedVideo(at: 10.1)
        live.receivedAudio(at: 10.1)
        #expect(live.state(at: 10.2) == .healthy)
        #expect(live.state(at: 10.5) == .concealing)
        #expect(live.state(at: 12.2) == .recovering)
        #expect(live.state(at: 40.2) == .failed)
    }

    @Test func oneHealthyTrackCannotHideAStalledTrack() {
        var live = CaptureLiveness(startedAt: 0)
        live.receivedAudio(at: 0)
        for second in 0...10 { live.receivedVideo(at: Double(second)) }
        #expect(live.state(at: 10) == .recovering)
        live.receivedAudio(at: 10)
        #expect(live.state(at: 10) == .healthy)
        #expect(CaptureLiveness(startedAt: 0).state(at: 6) == .recovering)
    }

    @Test func fillsOnlyMissingVideoTimesAndRejectsLateFrames() throws {
        var repair = VideoCaptureRepair(frameDuration: CMTime(value: 1, timescale: 30))
        repair.accepted(.zero)
        let missingResult = try repair.missingFrames(before: CMTime(value: 4, timescale: 30))
        let missing = try #require(missingResult)
        let expected: [Double] = [1.0 / 30, 2.0 / 30, 3.0 / 30]
        #expect(missing.map(\.seconds) == expected)
        for time in missing { repair.accepted(time) }
        #expect(try repair.missingFrames(before: CMTime(value: 2, timescale: 30)) == nil)
        #expect(try repair.missingFrames(before: CMTime(value: 4, timescale: 30))?.isEmpty == true)
        #expect(throws: CaptureContinuityError.self) { try repair.missingFrames(before: CMTime(value: 5, timescale: 1)) }
        #expect(throws: CaptureContinuityError.self) { try repair.missingFrames(before: .invalid) }
    }

    @Test func audioRepairPreservesRealTimingAndTrimsPartialDuplicates() throws {
        var repair = AudioCaptureRepair(sampleRate: 48_000)
        repair.accepted(pts: .zero, frames: 480)
        let gapResult = try repair.plan(pts: CMTime(value: 30, timescale: 1000), frames: 480)
        let gap = try #require(gapResult)
        #expect(gap.silenceFrames == 960)
        #expect(gap.silencePTS.seconds == 0.01)
        #expect(gap.inputPTS.seconds == 0.03)
        #expect(gap.trimFrames == 0)
        #expect(try repair.plan(pts: .zero, frames: 480) == nil)
        let partialResult = try repair.plan(pts: CMTime(value: 5, timescale: 1000), frames: 480)
        let partial = try #require(partialResult)
        #expect(partial.trimFrames == 240)
        #expect(partial.inputPTS.seconds == 0.01)
        #expect(partial.silenceFrames == 0)
    }

    @Test func distinguishesClockDriftFromMissingAudio() throws {
        var repair = AudioCaptureRepair(sampleRate: 48_000)
        for block in 0..<3600 {
            let pts = CMTime(seconds: Double(block) * 1.0001, preferredTimescale: 90_000)
            let planResult = try repair.plan(pts: pts, frames: 48_000)
            let plan = try #require(planResult)
            #expect(plan.silenceFrames == 0)
            #expect(plan.trimFrames == 0)
            repair.accepted(pts: pts, frames: 48_000)
        }
    }

    @Test func rejectsLargeAudioGapsAndExtremeBackwardTimesWithoutOverflow() throws {
        var repair = AudioCaptureRepair(sampleRate: 44_100)
        repair.accepted(pts: .zero, frames: 1024)
        #expect(throws: CaptureContinuityError.self) { try repair.plan(pts: CMTime(value: 3, timescale: 1), frames: 1024) }
        #expect(try repair.plan(pts: CMTime(value: Int64.min + 1, timescale: 1), frames: 1024) == nil)
    }

    @Test func timelineRefusesUnrepairedBackwardAudio() throws {
        var timeline = AudioSampleTimeline(sourceSampleRate: 44_100)
        try timeline.append(presentationTime: .zero, frames: 1024)
        #expect(throws: MediaEncodingError.self) {
            try timeline.append(presentationTime: CMTime(value: 2048, timescale: 44_100), frames: 1024)
        }
        #expect(throws: MediaEncodingError.self) {
            try timeline.append(presentationTime: .zero, frames: 1024)
        }
    }
}
