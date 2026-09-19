import Foundation
import Testing
@testable import Tubeist

struct AdaptiveBitrateControllerTests {
    private func controller() -> AdaptiveBitrateController {
        AdaptiveBitrateController(maximumBitrate: 6_000_000, minimumBitrate: 1_000_000, audioBitrate: 128_000)
    }

    private func observe(_ c: inout AdaptiveBitrateController, at now: Double,
                         bytes: Int = 0, seconds: Double = 0,
                         inFlightBytes: Int = 0, age: Double = 0, duration: Double = 2) {
        c.update(waitingBytes: bytes, waitingMediaSeconds: seconds, inFlightBytes: inFlightBytes,
                 inFlightDuration: duration, inFlightSeconds: age, now: now)
    }

    private func ack(_ c: inout AdaptiveBitrateController, at now: Double, capacity: Double,
                     elapsed: Double = 1, bytes: Int = 0, seconds: Double = 0) {
        c.delivered(bytes: Int(capacity * elapsed / 8), elapsed: elapsed, mediaDuration: 2, now: now)
        observe(&c, at: now, bytes: bytes, seconds: seconds)
    }

    @Test func ladderHasExactEndpointsAndUsefulUniqueSteps() {
        let ladder = BitrateLadder(maximum: 6_000_000, minimum: 1_000_000)
        #expect(ladder.rungs == [6_000_000, 4_800_000, 3_850_000, 3_050_000, 2_450_000,
                                1_950_000, 1_550_000, 1_250_000, 1_000_000])
        #expect(BitrateLadder(maximum: 99_999, minimum: 250_000).rungs == [99_999])
        #expect(BitrateLadder(maximum: 1_025_000, minimum: 1_000_000).rungs == [1_025_000, 1_000_000])
        #expect(BitrateLadder(maximum: 0, minimum: -1).rungs == [1])
        #expect(ladder.fitting(3_900_000) == 3_850_000)
        #expect(ladder.next(above: 3_850_000) == 4_800_000)
    }

    @Test func pollingOneSlowCompletionDoesNotCountItTwice() {
        var c = controller()
        ack(&c, at: 3, capacity: 4_000_000, elapsed: 3)
        for now in stride(from: 3.1, through: 20, by: 0.1) { observe(&c, at: now) }
        #expect(c.targetBitrate == 6_000_000)
        ack(&c, at: 21, capacity: 4_000_000, elapsed: 3)
        #expect(c.targetBitrate < 4_000_000)
    }

    @Test func stallBeforeFirstAckCanReduceAndCannotAuthorizeRecovery() {
        var c = controller()
        for now in stride(from: 4.0, through: 16, by: 2) {
            observe(&c, at: now, bytes: 3_000_000, seconds: 4, inFlightBytes: 1_500_000, age: now)
        }
        #expect(c.targetBitrate == c.minimumBitrate)
        #expect(c.state == .capacityBelowQualityFloor)
        for now in stride(from: 18.0, through: 60, by: 2) { observe(&c, at: now) }
        #expect(c.targetBitrate == c.minimumBitrate)
    }

    @Test func drainingOldLargeSegmentsNeitherRaisesNorRepeatedlyCutsTheTarget() {
        var c = controller()
        ack(&c, at: 4, capacity: 4_000_000, elapsed: 3, bytes: 2_000_000, seconds: 4)
        let reduced = c.targetBitrate
        #expect(reduced < 6_000_000)
        ack(&c, at: 5, capacity: 20_000_000, bytes: 1_500_000, seconds: 3)
        ack(&c, at: 6, capacity: 20_000_000, bytes: 1_000_000, seconds: 2)
        ack(&c, at: 7, capacity: 20_000_000, bytes: 500_000, seconds: 1)
        #expect(c.targetBitrate == reduced)
    }

    @Test func recentlyProvenQualityReturnsAfterFourSecondsOfFreshClearDelivery() {
        var c = controller()
        for now in stride(from: 0.0, through: 40, by: 2) { ack(&c, at: now, capacity: 12_000_000) }
        ack(&c, at: 42, capacity: 4_000_000, elapsed: 3, bytes: 1_000_000, seconds: 4)
        let reduced = c.targetBitrate
        for now in [44.0, 46] {
            ack(&c, at: now, capacity: 12_000_000)
            #expect(c.targetBitrate == reduced)
        }
        ack(&c, at: 48, capacity: 12_000_000)
        #expect(c.targetBitrate == 6_000_000)
    }

    @Test func fastBurstCannotReplaceWallClockRecoveryEvidence() {
        var c = controller()
        for now in stride(from: 0.0, through: 40, by: 2) { ack(&c, at: now, capacity: 12_000_000) }
        ack(&c, at: 42, capacity: 4_000_000, elapsed: 3, bytes: 1_000_000, seconds: 4)
        let reduced = c.targetBitrate
        for now in stride(from: 42.1, through: 44, by: 0.1) { ack(&c, at: now, capacity: 24_000_000, elapsed: 0.1) }
        #expect(c.targetBitrate == reduced)
    }

    @Test func transientPeakAfterSustainedCongestionDoesNotRaiseQuality() {
        var c = controller()
        ack(&c, at: 3, capacity: 3_000_000, elapsed: 3, bytes: 500_000, seconds: 4)
        for now in stride(from: 6.0, through: 60, by: 2) { ack(&c, at: now, capacity: 3_000_000) }
        let reduced = c.targetBitrate
        ack(&c, at: 62, capacity: 30_000_000)
        ack(&c, at: 64, capacity: 3_000_000)
        #expect(c.targetBitrate == reduced)
    }

    @Test func failedIncreaseRollsBackAndBlocksFurtherIncreases() {
        var c = controller()
        c.discardedBacklog(now: 0)
        for now in stride(from: 2.0, through: 20, by: 2) { ack(&c, at: now, capacity: 20_000_000) }
        let increased = c.targetBitrate
        #expect(increased == 1_250_000)
        ack(&c, at: 23, capacity: 1_000_000, elapsed: 3)
        ack(&c, at: 26, capacity: 1_000_000, elapsed: 3)
        #expect(c.targetBitrate == 1_000_000)
        for now in stride(from: 28.0, through: 44, by: 2) { ack(&c, at: now, capacity: 20_000_000) }
        #expect(c.targetBitrate == 1_000_000)
        ack(&c, at: 46, capacity: 20_000_000)
        #expect(c.targetBitrate == 1_250_000)
    }

    @Test func emptyQueueDuringLongCaptureGapDoesNotCountAsSustainedEvidence() {
        var c = controller()
        c.discardedBacklog(now: 0)
        ack(&c, at: 20, capacity: 20_000_000)
        ack(&c, at: 22, capacity: 20_000_000)
        ack(&c, at: 100, capacity: 20_000_000)
        #expect(c.targetBitrate == 1_000_000)
    }

    @Test func recurrentDipsDisableFastRestoration() {
        var c = controller()
        for now in stride(from: 0.0, through: 40, by: 2) { ack(&c, at: now, capacity: 12_000_000) }
        ack(&c, at: 42, capacity: 4_000_000, elapsed: 3, bytes: 1_000_000, seconds: 4)
        for now in [44.0, 46, 48] { ack(&c, at: now, capacity: 12_000_000) }
        #expect(c.targetBitrate == 6_000_000)
        ack(&c, at: 53, capacity: 4_000_000, elapsed: 3, bytes: 1_000_000, seconds: 4)
        let reduced = c.targetBitrate
        #expect(reduced < 6_000_000)
        for now in [54.0, 56, 58, 60, 62, 64] {
            ack(&c, at: now, capacity: 12_000_000)
            #expect(c.targetBitrate == reduced)
        }
    }

    @Test func uploadLatenessUsesItsActualMediaDuration() {
        var c = controller()
        observe(&c, at: 3, bytes: 1_000_000, seconds: 2, inFlightBytes: 3_000_000, age: 3, duration: 4)
        #expect(c.targetBitrate == 6_000_000)
        observe(&c, at: 6, bytes: 1_000_000, seconds: 2, inFlightBytes: 3_000_000, age: 6, duration: 4)
        #expect(c.targetBitrate < 6_000_000)
    }

    @Test func invalidSamplesAndObservationsCannotChangeTheTarget() {
        var c = controller()
        c.delivered(bytes: 0, elapsed: 1, mediaDuration: 2, now: 0)
        c.delivered(bytes: 1, elapsed: .nan, mediaDuration: 2, now: 0)
        c.delivered(bytes: 1, elapsed: 1, mediaDuration: 0, now: 0)
        observe(&c, at: .infinity)
        observe(&c, at: 1, seconds: .nan)
        #expect(c.estimatedThroughput == nil)
        #expect(c.targetBitrate == 6_000_000)
    }

    @Test(arguments: [0.0, 0.5, 1.0, 1.5])
    func shortHalvingAtDifferentSegmentPhasesRecoversWithoutDrops(phase: Double) {
        let result = simulate(seconds: 90) { now in (40 + phase..<42 + phase).contains(now) ? 5_000_000 : 10_000_000 }
        #expect(result.dropped == 0)
        #expect(result.maximumWaiting <= 4)
        #expect(result.rates.filter { $0.at >= 55 }.allSatisfy { $0.rate == 6_000_000 })
    }

    @Test func sustainedHalvingSettlesThenRecoversWithoutOscillation() {
        let result = simulate(seconds: 240) { now in (40..<140).contains(now) ? 5_000_000 : 10_000_000 }
        #expect(result.dropped == 0)
        #expect(result.maximumWaiting <= 8)
        let settled = result.rates.filter { (90..<140).contains($0.at) }.map(\.rate)
        #expect(Set(settled).count == 1)
        #expect(settled.first! < 5_000_000)
        #expect(result.rates.last!.rate == 6_000_000)
        #expect(result.rates.filter { $0.at >= 210 }.allSatisfy { $0.rate == 6_000_000 })
    }

    @Test func prolongedOutageUsesFloorAndStillEventuallyRestoresQuality() {
        let result = simulate(seconds: 240) { now in (40..<70).contains(now) ? 0 : 10_000_000 }
        #expect(result.dropped > 0)
        #expect(result.maximumWaiting <= 10)
        #expect(result.rates.contains { $0.rate == 1_000_000 })
        #expect(result.rates.last!.rate == 6_000_000)
    }

    @Test func briefPeakDuringSustainedLowCapacityDoesNotCauseAnIncrease() {
        let result = simulate(seconds: 180) { now in
            if (100..<102).contains(now) { return 20_000_000 }
            return now < 40 ? 10_000_000 : 4_000_000
        }
        let baseline = simulate(seconds: 180) { $0 < 40 ? 10_000_000 : 4_000_000 }
        let aroundPeak = result.rates.filter { (100..<110).contains($0.at) }.map(\.rate)
        let withoutPeak = baseline.rates.filter { (100..<110).contains($0.at) }.map(\.rate)
        #expect(aroundPeak == withoutPeak)
        #expect(result.dropped == 0)
    }

    private struct Trace {
        var dropped = 0
        var maximumWaiting = 0.0
        var rates: [(at: Double, rate: Int)] = []
    }

    /// A continuous link with serialized transactions, 80 ms request latency,
    /// variable segment sizes, and bitrate captured at the START of encoding.
    /// This includes the encoder/segment delay missing from instantaneous models.
    private func simulate(seconds: Double, capacity: (Double) -> Double) -> Trace {
        struct Segment {
            let bytes: Int
            let duration = 2.0
            var remaining: Double
            var started = 0.0
        }
        var c = controller()
        var queue: [Segment] = []
        var current: Segment?
        var nextArrival = 2.0
        var nextObservation = 0.0
        var encodingRate = c.targetBitrate
        var index = 0
        var trace = Trace()
        let dt = 0.02
        for step in 0...Int(seconds / dt) {
            let now = Double(step) * dt
            var event = false
            if now + 0.0001 >= nextArrival {
                let vbr = [0.90, 1.10, 1.0, 1.05, 0.95][index % 5]
                let bits = (Double(encodingRate) * vbr + 128_000) * 1.08 * 2
                if queue.count >= 5 {
                    trace.dropped += queue.count
                    queue.removeAll()
                    c.discardedBacklog(now: now)
                }
                queue.append(Segment(bytes: Int(bits / 8), remaining: bits))
                event = true
                nextArrival += 2
                index += 1
                encodingRate = c.targetBitrate
            }
            if var segment = current {
                if now - segment.started >= 0.08 { segment.remaining -= capacity(now) * dt }
                if segment.remaining <= 0 {
                    current = nil
                    event = true
                    c.delivered(bytes: segment.bytes, elapsed: now - segment.started, mediaDuration: 2, now: now)
                } else { current = segment }
            }
            if event || now >= nextObservation {
                observe(&c, at: now, bytes: queue.reduce(0) { $0 + $1.bytes }, seconds: Double(queue.count) * 2,
                        inFlightBytes: current?.bytes ?? 0, age: current.map { now - $0.started } ?? 0)
                nextObservation = now + 0.25
            }
            if current == nil, !queue.isEmpty {
                current = queue.removeFirst()
                current?.started = now
            }
            trace.maximumWaiting = max(trace.maximumWaiting, Double(queue.count) * 2)
            if step % 50 == 0 { trace.rates.append((now, c.targetBitrate)) }
        }
        return trace
    }
}
