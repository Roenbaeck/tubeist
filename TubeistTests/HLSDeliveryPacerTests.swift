import Testing
@testable import Tubeist

struct HLSDeliveryPacerTests {
    @Test(arguments: [(2.0, 1.1), (4, 1.2), (8, 1.4), (12, 1.6), (22, 2.1), (32, 2.6)])
    func initialRateMatchesTheRecoveryEquation(example: (Double, Double)) throws {
        var pacer = HLSDeliveryPacer()
        pacer.beganUpload(duration: 2, now: 0)
        let decision = pacer.decision(queuedMediaSeconds: example.0, nextDuration: 2, now: 0)
        #expect(abs((try #require(decision.rate)) - example.1) < 0.000001)
        #expect(abs(decision.delay - 2 / example.1) < 0.000001)
    }

    @Test func startupHasNoExtraBufferingDelay() {
        var pacer = HLSDeliveryPacer()
        #expect(pacer.decision(queuedMediaSeconds: 2, nextDuration: 2, now: 0).delay == 0)
        #expect(pacer.decision(queuedMediaSeconds: 12, nextDuration: 2, now: 0).delay == 0)
    }

    @Test func successfulRecoveryKeepsItsRateInsteadOfMovingTheDeadline() throws {
        var pacer = HLSDeliveryPacer()
        let initial = pacer.decision(queuedMediaSeconds: 12, nextDuration: 2, now: 0)
        let halfway = pacer.decision(queuedMediaSeconds: 6, nextDuration: 2, now: 10)
        #expect(initial.rate == 1.6)
        #expect(halfway.rate == 1.6)
        #expect(pacer.recoveryTimeRemaining(at: 10) == 10)
        let lastWaiting = pacer.decision(queuedMediaSeconds: 2, nextDuration: 2, now: 20)
        #expect(lastWaiting.reason == .recoveryDeadline)
        #expect(pacer.recoveryTimeRemaining(at: 20) == 0)
        pacer.beganUpload(duration: 2, now: 20)
        pacer.becameIdle() // The final upload was acknowledged with no waiting media.
        let caughtUp = pacer.decision(queuedMediaSeconds: 2, nextDuration: 2, now: 21)
        #expect(caughtUp.rate == 1)
        #expect(caughtUp.delay == 0) // Do not carry the old upload phase forward.
        #expect(pacer.recoveryTimeRemaining(at: 21) == nil)
    }

    @Test func failedRecoveryExceedsTwoTimesThenBecomesWorkConserving() throws {
        var pacer = HLSDeliveryPacer()
        _ = pacer.decision(queuedMediaSeconds: 10, nextDuration: 2, now: 0)
        let struggling = pacer.decision(queuedMediaSeconds: 10, nextDuration: 2, now: 15)
        #expect((try #require(struggling.rate)) == 3)
        let expired = pacer.decision(queuedMediaSeconds: 8, nextDuration: 2, now: 20)
        #expect(expired.reason == .recoveryDeadline)
        #expect(expired.delay == 0)
        #expect(expired.rate == nil)
        #expect(pacer.decision(queuedMediaSeconds: 6, nextDuration: 2, now: 40).rate == nil)
        pacer.becameIdle()
        #expect(pacer.decision(queuedMediaSeconds: 6, nextDuration: 2, now: 42).rate == 1.3)
    }

    @Test func durationAndCountBudgetsIndependentlyDisableWaiting() {
        var pacer = HLSDeliveryPacer()
        pacer.beganUpload(duration: 2, now: 0)
        for (duration, count) in [(50.0, 25), (2.8, 28)] {
            let decision = pacer.decision(queuedMediaSeconds: duration, nextDuration: 0.1, now: 0.1,
                                          queuedFragments: count)
            #expect(decision.reason == .queuePressure)
            #expect(decision.delay == 0)
            #expect(decision.rate == nil)
        }
    }

    @Test func shutdownBudgetOverridesPacingBeforeItCanConsumeTheTail() {
        var pacer = HLSDeliveryPacer()
        pacer.beganUpload(duration: 2, now: 10)
        #expect(pacer.decision(queuedMediaSeconds: 2, nextDuration: 2, now: 10.1, finishBy: 100).delay > 1)
        let urgent = pacer.decision(queuedMediaSeconds: 2, nextDuration: 2, now: 10.1, finishBy: 13)
        #expect(urgent.reason == .shutdownDeadline)
        #expect(urgent.delay == 0)
    }

    @Test(arguments: [Double.nan, Double.infinity, -1.0])
    func invalidQueueObservationsNeverProduceInvalidSleeps(value: Double) {
        var pacer = HLSDeliveryPacer()
        pacer.beganUpload(duration: 2, now: 0)
        let decision = pacer.decision(queuedMediaSeconds: value, nextDuration: 2, now: 1)
        #expect(decision.reason == .invalidObservation)
        #expect(decision.delay == 0)
    }

    @Test func transferTimeCountsTowardSpacingAndSlowUploadsNeverWait() {
        var pacer = HLSDeliveryPacer()
        pacer.beganUpload(duration: 2, now: 100)
        let decision = pacer.decision(queuedMediaSeconds: 12, nextDuration: 2, now: 100.5)
        #expect(abs(decision.delay - (2 / 1.6 - 0.5)) < 0.000001)
        #expect(pacer.decision(queuedMediaSeconds: 12, nextDuration: 2, now: 102.5).delay == 0)
    }

    @Test func longOutageDoesNotAccumulateBurstCredit() {
        var pacer = HLSDeliveryPacer()
        pacer.beganUpload(duration: 2, now: 0)
        #expect(pacer.decision(queuedMediaSeconds: 20, nextDuration: 2, now: 30).delay == 0)
        pacer.beganUpload(duration: 2, now: 30)
        #expect(pacer.decision(queuedMediaSeconds: 18, nextDuration: 2, now: 30.1).delay > 0)
    }

    @Test func changingBacklogAndSegmentLengthsChangeTheNextDeadline() {
        var pacer = HLSDeliveryPacer()
        pacer.beganUpload(duration: 3, now: 10)
        let small = pacer.decision(queuedMediaSeconds: 4, nextDuration: 2, now: 10.5)
        let large = pacer.decision(queuedMediaSeconds: 12, nextDuration: 2, now: 10.5)
        #expect(large.delay < small.delay)
        #expect(abs(large.delay - 1.375) < 0.000001)
        pacer.beganUpload(duration: 0.25, now: 12)
        let rateWithOneLeft = 1 + 2 / 18.5 // The deadline remains at 30.5.
        #expect(abs(pacer.decision(queuedMediaSeconds: 2, nextDuration: 2, now: 12).delay - 0.25 / rateWithOneLeft) < 0.000001)
    }

    @Test func oneSegmentWaitingAfterASlowUploadStartsRecovery() {
        var pacer = HLSDeliveryPacer()
        pacer.beganUpload(duration: 2, now: 0)
        let next = pacer.decision(queuedMediaSeconds: 2, nextDuration: 2, now: 3)
        #expect(next.reason == .recovering)
        #expect(next.rate == 1.1)
        #expect(pacer.recoveryTimeRemaining(at: 3) == 20)
        #expect(pacer.decision(queuedMediaSeconds: 2, nextDuration: 2, now: 23).reason == .recoveryDeadline)
    }

    @Test func ordinaryIdleDoesNotAllowBurstsBeforeAnyRecovery() {
        var pacer = HLSDeliveryPacer()
        pacer.beganUpload(duration: 2, now: 0)
        pacer.becameIdle()
        let next = pacer.decision(queuedMediaSeconds: 2, nextDuration: 2, now: 0.5)
        #expect(next.reason == .steady)
        #expect(next.rate == 1)
        #expect(next.delay == 1.5)
    }

    @Test func repeatedOutagesUseShortRecoveryWindowsInsteadOfAccumulatingToOverflow() {
        let capacity: (Double) -> Double = { now in
            now < 300 ? (now.truncatingRemainder(dividingBy: 5) < 1 ? 20 : 0) : 20
        }
        let adaptive = simulate(seconds: 420, fixedCap: false, capacity: capacity)
        let capped = simulate(seconds: 420, fixedCap: true, capacity: capacity)
        #expect(capped.dropped > 0) // The old 2x cap wastes the available link.
        #expect(adaptive.dropped == 0)
        #expect(adaptive.maximumQueue < 60)
        // After recovery, only the freshly produced segment may be in flight.
        #expect(adaptive.remaining <= 2)
        #expect(adaptive.maximumResidentAtEnd <= 1)
        #expect(adaptive.idleSecondsAtEnd > 0.5)
        #expect(adaptive.maximumRate > 2 || adaptive.usedDeadlineOverride)
        print("Repeated-outage trace: fixed cap dropped \(capped.dropped), deadline controller dropped \(adaptive.dropped); peak queue \(adaptive.maximumQueue)s, final pipeline \(adaptive.remaining)s, peak scheduled rate \(adaptive.maximumRate)x")
    }

    @Test(arguments: [0.2, 1.0, 1.8])
    func recoveredConnectionReturnsToIdleBetweenFreshSegments(uploadSeconds: Double) {
        let result = simulate(seconds: 180, fixedCap: false) { now in
            now < 10 ? 0 : 2 / uploadSeconds
        }
        #expect(result.dropped == 0)
        // Once aligned to arrivals, each two-second cycle is idle except for
        // the upload itself. Allow the simulator's 10 ms transfer quantization.
        #expect(result.idleSecondsAtEnd >= 30 * (1 - uploadSeconds / 2) - 0.3)
        #expect(result.maximumResidentAtEnd <= 1)
    }

    @Test func impossibleLinkRemainsBoundedAndDiscardsWholeOrderedSegments() {
        let result = simulate(seconds: 240, fixedCap: false) { _ in 0.2 }
        #expect(result.dropped > 0)
        #expect(result.maximumQueue <= 60)
        #expect(result.maximumCount <= 30)
    }

    @Test func longOutageRecoversWithoutPacingAnotherBurstAgainstAnOldSchedule() {
        let result = simulate(seconds: 180, fixedCap: false) { now in
            now >= 10 && now < 85 ? 0 : 10
        }
        #expect(result.dropped > 0)
        #expect(result.remaining <= 2)
        #expect(result.maximumResidentAtEnd <= 1)
        #expect(result.idleSecondsAtEnd > 0.5)
        #expect(result.maximumQueue <= 60)
    }

    @Test(arguments: [UInt64(1), 17, 42, 99])
    func variableSegmentDurationsAndBitratesRemainOrderedAndBounded(seed: UInt64) {
        let result = simulate(seconds: 300, fixedCap: false, seed: seed, variableSegments: true) { now in
            let phase = Int(now / 10) % 4
            return [5.0, 0, 0.8, 15][phase]
        }
        #expect(result.maximumQueue <= 60)
        #expect(result.maximumCount <= 30)
    }

    private struct SimulationResult {
        var dropped = 0
        var maximumQueue = 0.0
        var maximumCount = 0
        var remaining = 0.0
        var usedDeadlineOverride = false
        var maximumRate = 1.0
        var idleSecondsAtEnd = 0.0
        var maximumResidentAtEnd = 0
    }

    /// Transfer work is separate from media duration, so variable bitrate and
    /// outages do not accidentally turn the test into a mirror of the pacer.
    private func simulate(seconds: Int, fixedCap: Bool, seed: UInt64 = 1,
                          variableSegments: Bool = false, capacity: (Double) -> Double) -> SimulationResult {
        struct Segment {
            let id: Int
            let duration: Double
            var work: Double
        }
        var random = seed
        func sample() -> Double {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return Double(random >> 11) / Double(UInt64.max >> 11)
        }
        var pacer = HLSDeliveryPacer()
        var queue: [Segment] = []
        var inFlight: Segment?
        var produced = 0
        var accepted: [Int] = []
        var dropped: [Int] = []
        var result = SimulationResult()
        var nextArrival = 0.0
        var lastStart = -Double.infinity
        var lastDuration = 0.0
        let stepSeconds = 0.01
        for step in 0...(seconds * 100) {
            let now = Double(step) * stepSeconds
            if now >= nextArrival {
                let duration = variableSegments ? [0.25, 1.0, 2.0, 5.0][Int(sample() * 4) % 4] : 2
                let work = duration * (variableSegments ? 0.5 + sample() * 1.5 : 1)
                if queue.count >= 30 || queue.reduce(duration, { $0 + $1.duration }) > 60 {
                    while !queue.isEmpty && (queue.count >= 30 || queue.reduce(0, { $0 + $1.duration }) > max(0, 6 - duration)) {
                        dropped.append(queue.removeFirst().id)
                    }
                }
                queue.append(Segment(id: produced, duration: duration, work: work))
                produced += 1
                nextArrival += duration
            }
            if var segment = inFlight {
                segment.work -= capacity(now) * stepSeconds
                if segment.work <= 0 {
                    accepted.append(segment.id)
                    inFlight = nil
                    if queue.isEmpty { pacer.becameIdle() }
                } else {
                    inFlight = segment
                }
            }
            if inFlight == nil, let next = queue.first {
                let duration = queue.reduce(0) { $0 + $1.duration }
                let delay: Double
                if fixedCap {
                    let rate = min(2, 1 + max(0, duration - next.duration) / 20)
                    delay = max(0, lastStart + lastDuration / rate - now)
                } else {
                    let decision = pacer.decision(queuedMediaSeconds: duration, nextDuration: next.duration,
                                                  now: now, queuedFragments: queue.count)
                    delay = decision.delay
                    result.maximumRate = max(result.maximumRate, decision.rate ?? 1)
                    result.usedDeadlineOverride = result.usedDeadlineOverride || decision.reason == .recoveryDeadline
                }
                if delay <= 0.001 {
                    inFlight = queue.removeFirst()
                    pacer.beganUpload(duration: next.duration, now: now)
                    lastStart = now
                    lastDuration = next.duration
                }
            }
            result.maximumQueue = max(result.maximumQueue, queue.reduce(0) { $0 + $1.duration })
            result.maximumCount = max(result.maximumCount, queue.count)
            if now >= Double(seconds - 30) {
                let resident = queue.count + (inFlight == nil ? 0 : 1)
                if resident == 0 { result.idleSecondsAtEnd += stepSeconds }
                result.maximumResidentAtEnd = max(result.maximumResidentAtEnd, resident)
            }
        }
        // Every generated segment has exactly one fate. No duplication,
        // unexplained loss or reordering is permitted in any network trace.
        let all = accepted + dropped + queue.map(\.id) + (inFlight.map { [$0.id] } ?? [])
        #expect(all.sorted() == Array(0..<produced))
        #expect(zip(accepted, accepted.dropFirst()).allSatisfy { $0 < $1 })
        result.dropped = dropped.count
        result.remaining = queue.reduce(inFlight?.duration ?? 0) { $0 + $1.duration }
        return result
    }
}
