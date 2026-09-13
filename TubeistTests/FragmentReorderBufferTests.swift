import Foundation
import Testing
@testable import Tubeist

struct FragmentReorderBufferTests {
    private func fragment(_ sequence: Int) -> Fragment {
        Fragment(sequence: sequence, segment: Data([UInt8(sequence % 256)]), duration: 2, container: .mpegTransportStream)
    }

    @Test func restoresOrderAndIgnoresAlreadyDeliveredDuplicates() throws {
        var buffer = FragmentReorderBuffer()
        buffer.insert(fragment(1))
        #expect(try buffer.takeNext(now: 0) == nil)
        buffer.insert(fragment(0))
        #expect(try buffer.takeNext(now: 0.1)?.sequence == 0)
        #expect(try buffer.takeNext(now: 0.1)?.sequence == 1)
        buffer.insert(fragment(0))
        #expect(buffer.isEmpty)
    }

    @Test func skipsMissingSegmentsOnlyAfterABoundedWait() throws {
        var buffer = FragmentReorderBuffer()
        buffer.insert(fragment(3))
        #expect(try buffer.takeNext(now: 0) == nil)
        #expect(try buffer.takeNext(now: 1.9) == nil)
        let next = try buffer.takeNext(now: 2)
        let resumed = try #require(next)
        #expect(resumed.sequence == 3)
        #expect(resumed.discontinuity)
        #expect(buffer.nextSequence == 4)
    }

    @Test func boundsMemoryEvenWhenTheConsumerIsSuspended() throws {
        var buffer = FragmentReorderBuffer(maximumCount: 4)
        for sequence in 1...100 { buffer.insert(fragment(sequence)) }
        #expect(buffer.count == 4)
        buffer.insert(fragment(0))
        #expect(buffer.count == 4)
        #expect(try buffer.takeNext(now: 0)?.sequence == 0)
        #expect(try buffer.takeNext(now: 0)?.sequence == 1)
    }

    @Test func neverSkipsMP4Initialization() throws {
        var buffer = FragmentReorderBuffer(maximumCount: 1)
        buffer.insert(Fragment(sequence: 1, segment: Data(), duration: 2))
        #expect(throws: ContentPackagingError.self) { try buffer.takeNext(now: 0) }
    }
}
