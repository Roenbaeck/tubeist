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

    @Test(arguments: [false, true])
    func droppedFrameKeepsDecodeTimesAlignedWithEmittedFrames(reportedLate: Bool) throws {
        let duration = CMTime(value: 1, timescale: 30)
        let times = (0..<13).map { CMTimeMultiply(duration, multiplier: Int32($0)) }
        let order = [0, 4, 2, 1, 3, 8, 6, 5, 7, 12, 10, 9, 11]
        // A B picture, reported in its output slot, or late: after its own
        // timestamp was already used as the decode time of a later picture.
        let dropped = 6
        var timeline = VideoDecodeTimeline(frameDuration: duration)
        try timeline.configure(reorderFrames: 2)
        for time in times { timeline.submitted(time) }
        let emitted = order.filter { $0 != dropped }
        var events = emitted.map { Optional($0) }
        events.insert(nil, at: order.firstIndex(of: dropped)! + (reportedLate ? 3 : 0))
        var decoded: [CMTime] = []
        for event in events {
            guard let index = event else {
                try timeline.dropped(presentationTime: times[dropped])
                continue
            }
            let dts = try timeline.next(presentationTime: times[index])
            #expect(dts <= times[index])
            if let previous = decoded.last { #expect(dts > previous) }
            decoded.append(dts)
        }
        // The same timing as an encoder that was never given the dropped frame.
        var reference = VideoDecodeTimeline(frameDuration: duration)
        try reference.configure(reorderFrames: 2)
        for (index, time) in times.enumerated() where index != dropped { reference.submitted(time) }
        let expected = try emitted.map { try reference.next(presentationTime: times[$0]) }
        if reportedLate {
            // One decode time ran early before the drop was known, then realigned.
            #expect(zip(decoded, expected).allSatisfy { $0 <= $1 })
            #expect(decoded != expected)
            #expect(Array(decoded.suffix(3)) == Array(expected.suffix(3)))
        } else {
            #expect(decoded == expected)
        }
        // Every submitted frame is accounted for: nothing remains pending.
        #expect(throws: MediaEncodingError.self) { try timeline.next(presentationTime: times[12]) }
        #expect(throws: MediaEncodingError.self) { try timeline.dropped(presentationTime: times[12]) }
    }

    @Test func droppedFramesWithoutReorderingKeepDecodeTimesEqualToPresentation() throws {
        let duration = CMTime(value: 1, timescale: 60)
        var timeline = VideoDecodeTimeline(frameDuration: duration)
        try timeline.configure(reorderFrames: 0)
        let times = (0..<6).map { CMTimeMultiply(duration, multiplier: Int32($0)) }
        for time in times { timeline.submitted(time) }
        #expect(try timeline.next(presentationTime: times[0]) == times[0])
        try timeline.dropped(presentationTime: times[1]) // the first frame after a keyframe
        #expect(try timeline.next(presentationTime: times[2]) == times[2])
        // Frame 3 is dropped but reported only after frame 4 was emitted.
        #expect(try timeline.next(presentationTime: times[4]) == times[3])
        try timeline.dropped(presentationTime: times[3])
        #expect(try timeline.next(presentationTime: times[5]) == times[5])
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
