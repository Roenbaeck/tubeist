import CoreMedia
import Testing
@testable import Tubeist

struct VideoDecodeTimelineTests {
    @Test func irregularCaptureCadenceKeepsDecodeTimesIncreasingAndBeforePresentation() throws {
        let duration = CMTime(value: 1, timescale: 60)
        var timeline = VideoDecodeTimeline(frameDuration: duration, maximumFrameDelay: 8)
        let times = [0.0, 0.016, 0.033, 0.35, 0.37, 0.39, 0.41, 0.8, 0.82, 0.84, 0.86, 1.1, 1.12]
            .map { CMTime(seconds: $0, preferredTimescale: 90_000) }
        for time in times { timeline.submitted(time) }
        // Reference frames precede the B frames that depend on them.
        let order = [0, 4, 1, 2, 3, 8, 5, 6, 7, 12, 9, 10, 11]
        var decoded: [CMTime] = []
        for index in order {
            let dts = try timeline.next(presentationTime: times[index])
            #expect(dts <= times[index])
            if let previous = decoded.last { #expect(dts > previous) }
            decoded.append(dts)
        }
        #expect(Array(decoded.dropFirst(8)) == Array(times.prefix(5)))
    }

    @Test func steadyCadenceUsesFixedDecodeIntervals() throws {
        let duration = CMTime(value: 1, timescale: 60)
        var timeline = VideoDecodeTimeline(frameDuration: duration, maximumFrameDelay: 8)
        for index in 0..<120 {
            let pts = CMTimeMultiply(duration, multiplier: Int32(index))
            timeline.submitted(pts)
            #expect(try timeline.next(presentationTime: pts) == CMTimeMultiply(duration, multiplier: Int32(index - 8)))
        }
    }
}
