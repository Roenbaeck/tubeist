import CoreMedia
import Testing
@testable import Tubeist

struct VideoDecodeTimelineTests {
    @Test func irregularCaptureCadenceKeepsDecodeTimesIncreasingAndBeforePresentation() throws {
        let duration = CMTime(value: 1, timescale: 60)
        var timeline = VideoDecodeTimeline(frameDuration: duration)
        try timeline.configure(reorderFrames: 2)
        let times = [0.0, 0.016, 0.033, 0.35, 0.37, 0.39, 0.41, 0.8, 0.82, 0.84, 0.86, 1.1, 1.12]
            .map { CMTime(seconds: $0, preferredTimescale: 90_000) }
        for time in times { timeline.submitted(time) }
        // Hierarchical B-picture order observed in the iPhone's HEVC output.
        let order = [0, 4, 2, 1, 3, 8, 6, 5, 7, 12, 10, 9, 11]
        var decoded: [CMTime] = []
        var awaitingDisplay: [CMTime] = []
        for index in order {
            let dts = try timeline.next(presentationTime: times[index])
            #expect(dts <= times[index])
            if let previous = decoded.last { #expect(dts > previous) }
            decoded.append(dts)
            awaitingDisplay.append(times[index])
            awaitingDisplay.removeAll { $0 <= dts }
            #expect(awaitingDisplay.count <= 2)
        }
        #expect(Array(decoded.dropFirst(2)) == Array(times.prefix(11)))
    }

    @Test(arguments: [0, 1, 2, 4])
    func steadyCadenceUsesCodecDepthInsteadOfEncoderWindow(depth: Int) throws {
        let duration = CMTime(value: 1, timescale: 60)
        var timeline = VideoDecodeTimeline(frameDuration: duration)
        try timeline.configure(reorderFrames: depth)
        for index in 0..<120 {
            let pts = CMTimeMultiply(duration, multiplier: Int32(index))
            timeline.submitted(pts)
            #expect(try timeline.next(presentationTime: pts) == CMTimeMultiply(duration, multiplier: Int32(index - depth)))
        }
        #expect(throws: MediaEncodingError.self) { try timeline.next(presentationTime: .zero) }
    }

    @Test func shortDrainDoesNotRequireFillingTheReorderWindow() throws {
        var timeline = VideoDecodeTimeline(frameDuration: CMTime(value: 1, timescale: 30))
        timeline.submitted(.zero)
        #expect(throws: MediaEncodingError.self) { try timeline.next(presentationTime: .zero) }
        try timeline.configure(reorderFrames: 2)
        #expect(try timeline.next(presentationTime: .zero) == CMTime(value: -2, timescale: 30))
        #expect(throws: MediaEncodingError.self) { try timeline.next(presentationTime: .zero) }
    }

    @Test func formatChangesKeepTheExistingTimelineOrRequireANewEncoder() throws {
        let duration = CMTime(value: 1, timescale: 30)
        var timeline = VideoDecodeTimeline(frameDuration: duration)
        try timeline.configure(reorderFrames: 2)
        timeline.submitted(.zero)
        #expect(try timeline.next(presentationTime: .zero) == CMTime(value: -2, timescale: 30))
        try timeline.configure(reorderFrames: 2) // e.g. a bitrate-only format change
        timeline.submitted(duration)
        #expect(try timeline.next(presentationTime: duration) == CMTime(value: -1, timescale: 30))
        #expect(throws: MediaEncodingError.self) { try timeline.configure(reorderFrames: 3) }
        #expect(timeline.reorderFrames == 2)
        var recovered = VideoDecodeTimeline(frameDuration: duration)
        try recovered.configure(reorderFrames: 0)
        let pts = CMTime(value: 150, timescale: 30)
        recovered.submitted(pts)
        #expect(try recovered.next(presentationTime: pts) == pts)
    }

    @Test func rejectOrderingBeyondTheDeclaredDepth() throws {
        let duration = CMTime(value: 1, timescale: 30)
        var timeline = VideoDecodeTimeline(frameDuration: duration)
        try timeline.configure(reorderFrames: 0)
        timeline.submitted(.zero)
        timeline.submitted(duration)
        _ = try timeline.next(presentationTime: duration)
        #expect(throws: MediaEncodingError.self) { try timeline.next(presentationTime: .zero) }
    }
}
