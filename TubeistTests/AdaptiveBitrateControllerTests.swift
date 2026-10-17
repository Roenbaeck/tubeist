import Foundation
import Testing
@testable import Tubeist

struct AdaptiveBitrateControllerTests {
    /// Steady-state rules start at the ceiling and recover through the usual
    /// evidence; the startup and collapse ramps have their own tests.
    private func controller(rampsUpAtStartup: Bool = false,
                            rampsUpAfterCollapse: Bool = false) -> AdaptiveBitrateController {
        AdaptiveBitrateController(maximumBitrate: 6_000_000, minimumBitrate: 1_000_000, audioBitrate: 128_000,
                                  policy: .init(rampsUpAtStartup: rampsUpAtStartup,
                                                rampsUpAfterCollapse: rampsUpAfterCollapse))
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

    @Test func drainEstimateUsesOnlyCompletedUploads() {
        var c = controller()
        // A slow first connection is not evidence of a slow link.
        #expect(c.estimatedDrainSeconds(waitingBytes: 5_000_000, inFlightBytes: 1_000_000, inFlightSeconds: 9) == nil)
        ack(&c, at: 2, capacity: 4_000_000)
        #expect(c.estimatedDrainSeconds(waitingBytes: 5_000_000, inFlightBytes: 0, inFlightSeconds: 0) == 10)
        // Credit the active upload with the time it has already been sending.
        #expect(c.estimatedDrainSeconds(waitingBytes: 5_000_000, inFlightBytes: 1_000_000, inFlightSeconds: 1) == 11)
        #expect(c.estimatedDrainSeconds(waitingBytes: 5_000_000, inFlightBytes: 1_000_000, inFlightSeconds: 5) == 10)
        // After a dip, the slower EWMA remains the optimistic estimate.
        ack(&c, at: 4, capacity: 1_000_000, elapsed: 2)
        #expect(c.estimatedDrainSeconds(waitingBytes: 5_000_000, inFlightBytes: 0, inFlightSeconds: 0)! > 10)
        #expect(c.estimatedDrainSeconds(waitingBytes: 5_000_000, inFlightBytes: 0, inFlightSeconds: 0)! < 11)
        #expect(c.estimatedDrainSeconds(waitingBytes: -1, inFlightBytes: 0, inFlightSeconds: 0) == nil)
        #expect(c.estimatedDrainSeconds(waitingBytes: 0, inFlightBytes: 0, inFlightSeconds: .nan) == nil)
    }

    @Test func drainEstimateDuringAReductionUsesTheCutCapacity() {
        var c = controller()
        ack(&c, at: 2, capacity: 10_000_000)
        ack(&c, at: 4, capacity: 10_000_000)
        #expect(c.estimatedDrainSeconds(waitingBytes: 2_500_000, inFlightBytes: 0, inFlightSeconds: 0)! < 3)
        // The slow EWMA still remembers 10 Mbps; queued media would take ten seconds.
        ack(&c, at: 9, capacity: 2_000_000, elapsed: 3, bytes: 2_000_000, seconds: 4)
        #expect(c.state == .capacityBelowQualityFloor)
        #expect(c.estimatedDrainSeconds(waitingBytes: 2_500_000, inFlightBytes: 0, inFlightSeconds: 0) == 10)
    }

    @Test func startingFarAboveCapacityDropsDoomedSegmentsInsteadOfDelayingLiveMedia() {
        // Without the startup ramp, three ceiling-rate segments are encoded before
        // the first ACK; together they would take 30 seconds to upload over this link.
        let result = simulate(seconds: 120, maximum: 20_000_000, rampsUpAtStartup: false) { _ in 4_000_000 }
        #expect(result.maximumLatency < 11)
        #expect(result.dropped <= 3)
        #expect(result.rates.filter { $0.at >= 20 }.allSatisfy { $0.rate < 4_000_000 })
    }

    @Test func startupBeginsAtTheFloorAndClimbsOnClearUploads() {
        var c = controller(rampsUpAtStartup: true)
        #expect(c.targetBitrate == 1_000_000)
        #expect(c.state == .recovering)
        // A 20 Mbps link, but the 1.5 Mbps segment just measured caps the step at four times its rate.
        ack(&c, at: 2, capacity: 20_000_000, elapsed: 0.15)
        #expect(c.targetBitrate == 4_800_000)
        ack(&c, at: 4, capacity: 20_000_000, elapsed: 0.5)
        #expect(c.targetBitrate == 6_000_000)
        #expect(c.state == .steady)
    }

    @Test func startupRampStopsWhereTheLinkHasNoRoomAndAfterItsWindow() {
        var c = controller(rampsUpAtStartup: true)
        // 1.4 Mbps leaves no room above the floor with 10% headroom.
        ack(&c, at: 2, capacity: 1_400_000, elapsed: 1.5)
        #expect(c.targetBitrate == 1_000_000)
        var late = c
        ack(&late, at: 40, capacity: 20_000_000, elapsed: 0.15)
        #expect(late.targetBitrate == 1_000_000)
        ack(&c, at: 30, capacity: 20_000_000, elapsed: 0.15)
        #expect(c.targetBitrate == 4_800_000)
    }

    @Test func congestionEndsTheStartupRamp() {
        // A collapse right after a ramp raise means the ramp overshot: no recovery ramp.
        var c = controller(rampsUpAtStartup: true, rampsUpAfterCollapse: true)
        ack(&c, at: 2, capacity: 20_000_000, elapsed: 0.15)
        ack(&c, at: 7, capacity: 2_000_000, elapsed: 3, bytes: 1_000_000, seconds: 4)
        let reduced = c.targetBitrate
        #expect(reduced < 4_800_000)
        // Still inside the window, but the ramp no longer skips the usual evidence.
        ack(&c, at: 9, capacity: 20_000_000, elapsed: 0.15)
        #expect(c.targetBitrate == reduced)
    }

    @Test func collapseRampsBackOnceTwoSpacedUploadsAgree() {
        var c = controller(rampsUpAfterCollapse: true)
        ack(&c, at: 2, capacity: 8_000_000)
        ack(&c, at: 5, capacity: 1_500_000, elapsed: 3, bytes: 1_000_000, seconds: 4)
        #expect(c.targetBitrate == 1_000_000)
        // The first fast upload after the collapse may be a brief peak.
        ack(&c, at: 7, capacity: 12_000_000, elapsed: 0.5)
        #expect(c.targetBitrate == 1_000_000)
        ack(&c, at: 9, capacity: 12_000_000, elapsed: 0.5)
        #expect(c.targetBitrate == 6_000_000)
    }

    @Test func burstsAndRecurringCollapsesDoNotRampBack() {
        var c = controller(rampsUpAfterCollapse: true)
        ack(&c, at: 2, capacity: 8_000_000)
        ack(&c, at: 5, capacity: 1_500_000, elapsed: 3, bytes: 1_000_000, seconds: 4)
        var burst = c
        ack(&burst, at: 7, capacity: 12_000_000, elapsed: 0.05)
        ack(&burst, at: 7.1, capacity: 12_000_000, elapsed: 0.05)
        #expect(burst.targetBitrate == 1_000_000)
        ack(&c, at: 7, capacity: 12_000_000, elapsed: 0.5)
        ack(&c, at: 9, capacity: 12_000_000, elapsed: 0.5)
        #expect(c.targetBitrate == 6_000_000)
        // A second collapse within three minutes: the link must earn its quality back.
        ack(&c, at: 40, capacity: 1_500_000, elapsed: 3, bytes: 1_000_000, seconds: 4)
        #expect(c.targetBitrate == 1_000_000)
        ack(&c, at: 42, capacity: 12_000_000, elapsed: 0.5)
        ack(&c, at: 44, capacity: 12_000_000, elapsed: 0.5)
        #expect(c.targetBitrate == 1_000_000)
    }

    @Test func seriousDropRecoversQuicklyOnceBandwidthReturns() {
        let capacity: (Double) -> Double = { (40..<60).contains($0) ? 2_000_000 : 10_000_000 }
        let result = simulate(seconds: 120, capacity: capacity)
        let cautious = simulate(seconds: 120, rampsUpAfterCollapse: false, capacity: capacity)
        let restored = { (trace: Trace) in trace.rates.first { $0.at >= 60 && $0.rate == 6_000_000 }?.at ?? .infinity }
        #expect(restored(result) < 80)
        #expect(restored(cautious) > 100)
        #expect(result.dropped <= cautious.dropped)
        #expect(result.maximumLatency <= cautious.maximumLatency)
    }

    @Test(arguments: [15.0, 30.0])
    func flappingLinkFallsBackToCautiousRecovery(period: Double) {
        let capacity: (Double) -> Double = { Int($0 / period) % 2 == 0 ? 10_000_000 : 2_000_000 }
        let result = simulate(seconds: 300, capacity: capacity)
        let cautious = simulate(seconds: 300, rampsUpAfterCollapse: false, capacity: capacity)
        // At most one fast recovery: one more collapse at a higher rate than before.
        #expect(result.dropped <= cautious.dropped + 2)
        #expect(result.maximumLatency <= cautious.maximumLatency + 2)
    }

    @Test(arguments: [(6_000_000, 3_000_000), (6_000_000, 10_000_000), (6_000_000, 50_000_000),
                      (20_000_000, 4_000_000), (20_000_000, 50_000_000)])
    func startupNeverDelaysTheFirstSegmentsAndReachesWhatTheLinkSustains(maximum: Int, link: Double) {
        let result = simulate(seconds: 60, maximum: maximum) { _ in link }
        #expect(result.dropped == 0)
        #expect(result.maximumLatency < 2.5)
        // Within 15 seconds: the ceiling when the link has room, otherwise near capacity.
        let settled = result.rates.first { $0.at >= 15 }!.rate
        let sustainable = 0.85 * link / 1.08 - 128_000
        #expect(settled == maximum || Double(settled) > 0.5 * sustainable)
        #expect(Double(settled) <= sustainable)
    }

    @Test(arguments: [0.0, 4.0, 8.0])
    func gradualCollapseDropsOldOversizedSegmentsRatherThanNewOnes(rampSeconds: Double) {
        // Ceiling-rate segments encoded before the first cut cannot drain at 2 Mbps.
        // Waiting until ten seconds of small, newer media overflow keeps the old
        // segments and discards the new ones.
        let result = simulate(seconds: 120) { now in
            now < 40 ? 10_000_000 : max(2_000_000, 10_000_000 - 8_000_000 * (now - 40) / max(rampSeconds, 0.001))
        }
        #expect(result.maximumLatency < 11)
        #expect(result.dropped < 5)
        #expect(result.rates.filter { $0.at >= 60 }.allSatisfy { $0.rate < 2_000_000 })
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
        var maximumLatency = 0.0
        var rates: [(at: Double, rate: Int)] = []
    }

    /// A continuous link with serialized transactions, 80 ms request latency,
    /// variable segment sizes, and bitrate captured at the START of encoding.
    /// This includes the encoder/segment delay missing from instantaneous models.
    /// Overflow mirrors the sink: queued media duration or estimated drain time.
    private func simulate(seconds: Double, maximum: Int = 6_000_000, rampsUpAtStartup: Bool = true,
                          rampsUpAfterCollapse: Bool = true, capacity: (Double) -> Double) -> Trace {
        struct Segment {
            let bytes: Int
            let duration = 2.0
            let arrived: Double
            var remaining: Double
            var started = 0.0
        }
        var c = AdaptiveBitrateController(maximumBitrate: maximum, minimumBitrate: 1_000_000, audioBitrate: 128_000,
                                          policy: .init(rampsUpAtStartup: rampsUpAtStartup,
                                                        rampsUpAfterCollapse: rampsUpAfterCollapse))
        var queue: [Segment] = []
        var current: Segment?
        var nextArrival = 2.0
        var nextObservation = 0.0
        var encodingRate = c.targetBitrate
        var index = 0
        var needsLiveCatchup = false
        var trace = Trace()
        let dt = 0.02
        for step in 0...Int(seconds / dt) {
            let now = Double(step) * dt
            var event = false
            if now + 0.0001 >= nextArrival {
                let vbr = [0.90, 1.10, 1.0, 1.05, 0.95][index % 5]
                let bits = (Double(encodingRate) * vbr + 128_000) * 1.08 * 2
                let drain = queue.isEmpty ? nil : c.estimatedDrainSeconds(
                    waitingBytes: queue.reduce(Int(bits / 8)) { $0 + $1.bytes }, inFlightBytes: current?.bytes ?? 0,
                    inFlightSeconds: current.map { now - $0.started } ?? 0)
                if queue.count >= 5 || drain ?? 0 > 10 {
                    trace.dropped += queue.count
                    queue.removeAll()
                    c.discardedBacklog(now: now)
                    needsLiveCatchup = true
                }
                queue.append(Segment(bytes: Int(bits / 8), arrived: now, remaining: bits))
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
                    trace.maximumLatency = max(trace.maximumLatency, now - segment.arrived)
                    c.delivered(bytes: segment.bytes, elapsed: now - segment.started, mediaDuration: 2, now: now)
                } else { current = segment }
            }
            if event || now >= nextObservation {
                observe(&c, at: now, bytes: queue.reduce(0) { $0 + $1.bytes }, seconds: Double(queue.count) * 2,
                        inFlightBytes: current?.bytes ?? 0, age: current.map { now - $0.started } ?? 0)
                nextObservation = now + 0.25
            }
            if current == nil, !queue.isEmpty {
                // Overflow during a stall, or an ACK revealing an undeliverable
                // backlog: resume with the newest segment, as the sink does.
                if queue.count > 1, needsLiveCatchup || c.estimatedDrainSeconds(
                    waitingBytes: queue.reduce(0) { $0 + $1.bytes }, inFlightBytes: 0, inFlightSeconds: 0) ?? 0 > 10 {
                    trace.dropped += queue.count - 1
                    queue.removeFirst(queue.count - 1)
                    c.discardedBacklog(now: now)
                }
                needsLiveCatchup = false
                current = queue.removeFirst()
                current?.started = now
            }
            trace.maximumWaiting = max(trace.maximumWaiting, Double(queue.count) * 2)
            if step % 50 == 0 { trace.rates.append((now, c.targetBitrate)) }
        }
        return trace
    }
}
