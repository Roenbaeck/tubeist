import CoreMedia
import Testing
@testable import Tubeist

struct RecordingAudioTimelineTests {
    private let duration = CMTime(value: 1024, timescale: 44_100)

    @Test func continuousAudioNeedsNoPadding() throws {
        var timeline = RecordingAudioTimeline()
        for packet in 0..<1_000 {
            let pts = CMTime(value: 9_871 + Int64(packet) * 1024, timescale: 44_100)
            #expect(try !timeline.needsSilence(before: pts, packetDuration: duration))
            timeline.appended(pts: pts, duration: duration)
        }
    }

    @Test func fractionalPacketGapsDoNotAccumulateRoundingError() throws {
        var timeline = RecordingAudioTimeline()
        var source = CMTime(value: 2_048, timescale: 44_100)
        var totalPadding = 0
        for recovery in 0..<1_000 {
            if recovery > 0 {
                source = CMTimeAdd(source, CMTime(value: Int64(27_017 + recovery % 977), timescale: 44_100))
            }
            while try timeline.needsSilence(before: source, packetDuration: duration) {
                timeline.appended(pts: try #require(timeline.end), duration: duration)
                totalPadding += 1
            }
            if let end = timeline.end {
                #expect(abs(CMTimeSubtract(source, end).seconds) <= duration.seconds / 2 + 1e-9)
            }
            timeline.appended(pts: source, duration: duration)
            source = CMTimeAdd(source, duration)
        }
        #expect(totalPadding > 20_000)
    }

    @Test func invalidTimingAndUnboundedGapsAreRejected() throws {
        var timeline = RecordingAudioTimeline()
        timeline.appended(pts: .zero, duration: duration)
        #expect(throws: (any Error).self) {
            try timeline.needsSilence(before: .invalid, packetDuration: duration)
        }
        #expect(throws: (any Error).self) {
            try timeline.needsSilence(before: duration, packetDuration: .zero)
        }
        #expect(throws: (any Error).self) {
            try timeline.needsSilence(before: CMTime(seconds: 61, preferredTimescale: 44_100), packetDuration: duration)
        }
    }
}
