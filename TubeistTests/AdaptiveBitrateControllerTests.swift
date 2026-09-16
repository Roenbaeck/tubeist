import Testing
@testable import Tubeist

struct AdaptiveBitrateControllerTests {
    @Test func shrinkingRecoveryBudgetDoesNotRenewTheBitrateAllowance() {
        var relaxed = AdaptiveBitrateController(maximumBitrate: 15_000_000,
            minimumBitrate: 1_000_000, audioBitrate: 128_000)
        var urgent = relaxed
        for now in [0.0, 2.0, 4.0] {
            for seconds in [20.0, 2.0] {
                var controller = seconds == 20 ? relaxed : urgent
                controller.delivered(bytes: 3_750_000, elapsed: 1)
                controller.update(queuedBytes: 10_000_000, queuedMediaSeconds: 8,
                    inFlightBytes: 0, inFlightSeconds: 0, now: now,
                    pacedRecoverySeconds: seconds)
                if seconds == 20 { relaxed = controller } else { urgent = controller }
            }
        }
        #expect(relaxed.targetBitrate == 15_000_000)
        #expect(urgent.targetBitrate < relaxed.targetBitrate)
    }

    @Test func deliberatePacingDoesNotDemandAnUnnecessarilyFastBitrateRecovery() {
        var paced = AdaptiveBitrateController(maximumBitrate: 15_000_000,
            minimumBitrate: 1_000_000, audioBitrate: 128_000)
        var unpaced = paced
        for now in [0.0, 2.0, 4.0, 6.0] {
            for isPaced in [false, true] {
                var controller = isPaced ? paced : unpaced
                controller.delivered(bytes: 3_750_000, elapsed: 1) // 30 Mbps.
                controller.update(queuedBytes: 15_000_000, queuedMediaSeconds: 8,
                    inFlightBytes: 0, inFlightSeconds: 0, now: now,
                    pacedRecoverySeconds: isPaced ? 20 : nil)
                if isPaced { paced = controller } else { unpaced = controller }
            }
        }
        #expect(paced.targetBitrate == 15_000_000)
        #expect(unpaced.targetBitrate < paced.targetBitrate)
    }

    @Test func pacingAllowanceStillRespondsToRealNetworkCongestion() {
        var controller = controller()
        for now in [0.0, 2.0, 4.0, 6.0] {
            controller.delivered(bytes: 1_000_000, elapsed: 3)
            controller.update(queuedBytes: 8_000_000, queuedMediaSeconds: 12,
                inFlightBytes: 1_000_000, inFlightSeconds: 5, now: now,
                pacedRecoverySeconds: 20)
        }
        #expect(controller.targetBitrate < 6_000_000)
    }

    private func controller() -> AdaptiveBitrateController {
        AdaptiveBitrateController(maximumBitrate: 6_000_000, minimumBitrate: 1_000_000, audioBitrate: 128_000)
    }

    @Test func isolatedSlowUploadDoesNotChangeQuality() {
        var controller = controller()
        controller.delivered(bytes: 1_600_000, elapsed: 1)
        controller.update(queuedBytes: 3_200_000, queuedMediaSeconds: 4, inFlightBytes: 1_600_000, inFlightSeconds: 3, now: 0)
        controller.update(queuedBytes: 0, queuedMediaSeconds: 0, inFlightBytes: 0, inFlightSeconds: 0, now: 2)
        #expect(controller.targetBitrate == 6_000_000)
    }

    @Test func sustainedMildCongestionReducesGradually() {
        var controller = controller()
        controller.delivered(bytes: 1_500_000, elapsed: 2.2)
        for now in [0.0, 2.0] {
            controller.update(queuedBytes: 2_500_000, queuedMediaSeconds: 3.2, inFlightBytes: 1_500_000, inFlightSeconds: 2.2, now: now)
            #expect(controller.targetBitrate == 6_000_000)
        }
        controller.update(queuedBytes: 2_500_000, queuedMediaSeconds: 3.2, inFlightBytes: 1_500_000, inFlightSeconds: 2.2, now: 4)
        #expect(controller.targetBitrate == 5_400_000)
        #expect(controller.state == .catchingUp)
    }

    @Test func noFirstAckCanStillCorrectGrosslyExcessivePreset() {
        var controller = AdaptiveBitrateController(maximumBitrate: 20_000_000, minimumBitrate: 1_000_000, audioBitrate: 128_000)
        for now in stride(from: 2.0, through: 10.0, by: 2) {
            controller.update(queuedBytes: Int((now + 2) * 2_500_000), queuedMediaSeconds: now + 2,
                              inFlightBytes: 5_000_000, inFlightSeconds: now, now: now)
        }
        #expect(controller.targetBitrate < 10_000_000)
        #expect(controller.targetBitrate >= 1_000_000)
    }

    @Test func repeatedObservationsWithinSegmentCannotAccelerateReduction() {
        var controller = controller()
        controller.delivered(bytes: 1_500_000, elapsed: 3)
        for now in stride(from: 0.0, to: 1.9, by: 0.01) {
            controller.update(queuedBytes: 8_000_000, queuedMediaSeconds: 10, inFlightBytes: 1_500_000, inFlightSeconds: 3, now: now)
        }
        #expect(controller.targetBitrate == 6_000_000)
    }

    @Test func qualityFloorIsReportedInsteadOfReducingWithoutLimit() {
        var controller = controller()
        controller.delivered(bytes: 100_000, elapsed: 5)
        for now in [0.0, 2.0, 4.0] {
            controller.update(queuedBytes: 10_000_000, queuedMediaSeconds: 12, inFlightBytes: 1_500_000, inFlightSeconds: 10, now: now)
        }
        #expect(controller.targetBitrate == 1_000_000)
        #expect(controller.state == .capacityBelowQualityFloor)
    }

    private func reducedFifteenMegabitController() -> AdaptiveBitrateController {
        var controller = AdaptiveBitrateController(maximumBitrate: 15_000_000,
            minimumBitrate: 10_000_000, audioBitrate: 128_000)
        // A previously healthy 30 Mbps connection stalls. The unfinished
        // upload bounds current capacity before a new measurement arrives.
        controller.delivered(bytes: 3_750_000, elapsed: 1)
        for now in [0.0, 2.0, 4.0] {
            controller.update(queuedBytes: 7_500_000, queuedMediaSeconds: 10,
                inFlightBytes: 3_750_000, inFlightSeconds: 6, now: now)
        }
        #expect(controller.targetBitrate == 10_000_000)
        return controller
    }

    @Test func restoredCapacityImmediatelyReturnsTenToFifteenMegabits() {
        var controller = reducedFifteenMegabitController()
        controller.delivered(bytes: 3_750_000, elapsed: 1)
        controller.update(queuedBytes: 0, queuedMediaSeconds: 0,
            inFlightBytes: 0, inFlightSeconds: 0, now: 6)
        #expect(controller.targetBitrate == 15_000_000)
        #expect(controller.state == .steady)
    }

    @Test func oldFastMeasurementsCannotUndoReduction() {
        var controller = reducedFifteenMegabitController()
        for now in stride(from: 6.0, through: 60.0, by: 2) {
            controller.update(queuedBytes: 0, queuedMediaSeconds: 0, inFlightBytes: 0, inFlightSeconds: 0, now: now)
            #expect(controller.targetBitrate == 10_000_000)
        }
    }

    @Test func latestSlowUploadCapsHistoricallyHighCapacity() {
        var controller = reducedFifteenMegabitController()
        controller.delivered(bytes: 1_000_000, elapsed: 1)
        controller.update(queuedBytes: 0, queuedMediaSeconds: 0,
            inFlightBytes: 0, inFlightSeconds: 0, now: 6)
        #expect(controller.estimatedThroughput! > 15_000_000)
        #expect(controller.targetBitrate == 10_000_000)
    }

    @Test func oneFastOutlierDoesNotOverrideSustainedLowCapacity() {
        var controller = reducedFifteenMegabitController()
        for _ in 0..<20 { controller.delivered(bytes: 1_000_000, elapsed: 1) }
        controller.delivered(bytes: 3_750_000, elapsed: 1)
        controller.update(queuedBytes: 0, queuedMediaSeconds: 0,
            inFlightBytes: 0, inFlightSeconds: 0, now: 6)
        #expect(controller.targetBitrate == 10_000_000)
    }

    @Test func recoveryReservesBandwidthBeyondVideoBitrate() {
        var controller = reducedFifteenMegabitController()
        controller.delivered(bytes: 2_000_000, elapsed: 1) // 16 Mbps total, not video alone.
        controller.update(queuedBytes: 0, queuedMediaSeconds: 0,
            inFlightBytes: 0, inFlightSeconds: 0, now: 6)
        #expect(controller.targetBitrate > 10_000_000)
        #expect(controller.targetBitrate < 15_000_000)
        #expect(Double(controller.targetBitrate + 128_000) * 1.08 <= 16_000_000 * 0.92)
    }

    @Test func ampleCapacityRestoresTargetWhileBacklogStillDrains() {
        var controller = reducedFifteenMegabitController()
        controller.delivered(bytes: 3_750_000, elapsed: 1)
        controller.update(queuedBytes: 6_000_000, queuedMediaSeconds: 4,
            inFlightBytes: 3_000_000, inFlightSeconds: 1, now: 6)
        #expect(controller.targetBitrate == 15_000_000)
    }

    @Test func largeBacklogKeepsRecoveredCapacityAvailableForCatchUp() {
        var controller = reducedFifteenMegabitController()
        controller.delivered(bytes: 3_750_000, elapsed: 1)
        controller.update(queuedBytes: 15_000_000, queuedMediaSeconds: 8,
            inFlightBytes: 3_000_000, inFlightSeconds: 1, now: 6)
        #expect(controller.targetBitrate == 10_000_000)
    }

    @Test func eachRecoveryDecisionNeedsANewCompletedUpload() {
        var controller = reducedFifteenMegabitController()
        controller.delivered(bytes: 3_750_000, elapsed: 1)
        controller.update(queuedBytes: 8_500_000, queuedMediaSeconds: 6,
            inFlightBytes: 3_000_000, inFlightSeconds: 1, now: 6)
        let partialRecovery = controller.targetBitrate
        #expect(partialRecovery > 10_000_000 && partialRecovery < 15_000_000)
        controller.update(queuedBytes: 0, queuedMediaSeconds: 0,
            inFlightBytes: 0, inFlightSeconds: 0, now: 8)
        #expect(controller.targetBitrate == partialRecovery)
        controller.delivered(bytes: 3_750_000, elapsed: 1)
        controller.update(queuedBytes: 0, queuedMediaSeconds: 0,
            inFlightBytes: 0, inFlightSeconds: 0, now: 10)
        #expect(controller.targetBitrate == 15_000_000)
    }

    @Test func anotherStalledUploadPreventsPrematureRecovery() {
        var controller = reducedFifteenMegabitController()
        controller.delivered(bytes: 3_750_000, elapsed: 1)
        controller.update(queuedBytes: 7_500_000, queuedMediaSeconds: 4,
            inFlightBytes: 3_750_000, inFlightSeconds: 6, now: 6)
        #expect(controller.targetBitrate == 10_000_000)
    }

    @Test func freshDeliveryWaitsOnlyForNextDecisionBoundary() {
        var controller = reducedFifteenMegabitController()
        controller.delivered(bytes: 3_750_000, elapsed: 1)
        for now in stride(from: 4.1, to: 6, by: 0.1) {
            controller.update(queuedBytes: 0, queuedMediaSeconds: 0,
                inFlightBytes: 0, inFlightSeconds: 0, now: now)
            #expect(controller.targetBitrate == 10_000_000)
        }
        controller.update(queuedBytes: 0, queuedMediaSeconds: 0,
            inFlightBytes: 0, inFlightSeconds: 0, now: 6)
        #expect(controller.targetBitrate == 15_000_000)
    }

    @Test func invalidMeasurementsAndLowSelectedCeilingAreSafe() {
        var controller = AdaptiveBitrateController(maximumBitrate: 100_000, minimumBitrate: 1_000_000, audioBitrate: 64_000)
        controller.delivered(bytes: 0, elapsed: .nan)
        controller.delivered(bytes: 100, elapsed: 0)
        controller.update(queuedBytes: 0, queuedMediaSeconds: 0, inFlightBytes: 0, inFlightSeconds: 0, now: .infinity)
        #expect(controller.targetBitrate == 100_000)
        #expect(controller.minimumBitrate == 100_000)
        #expect(controller.estimatedThroughput == nil)
    }

    @Test func leakyBucketTraceDrainsBacklogWithoutOscillating() {
        struct Segment {
            var remainingBits: Double
            let totalBytes: Int
            var startedAt: Double?
        }
        var controller = controller()
        var queue: [Segment] = []
        var maximumQueue = 0
        var minimumRate = controller.targetBitrate
        var rateAtRecoveryStart = 0
        var fullRecoveryTime: Double?
        var settledRates: [Int] = []
        var nextSegmentTime = 0.0
        // 20s healthy, a sustained 25% bandwidth deficit, then recovery.
        // Transfers progress continuously; samples arrive in two-second bursts.
        for step in 0..<3000 {
            let now = Double(step) / 10
            let capacity = now < 20 || now >= 120 ? 10_000_000.0 : 4_500_000.0
            if now >= nextSegmentTime {
                let wireBits = Double(controller.targetBitrate + 128_000) * 1.08 * 2
                queue.append(Segment(remainingBits: wireBits, totalBytes: Int(wireBits / 8)))
                nextSegmentTime += 2
            }
            if !queue.isEmpty {
                if queue[0].startedAt == nil { queue[0].startedAt = now }
                queue[0].remainingBits -= capacity / 10
                if queue[0].remainingBits <= 0 {
                    let delivered = queue.removeFirst()
                    controller.delivered(bytes: delivered.totalBytes, elapsed: now + 0.1 - delivered.startedAt!)
                }
            }
            controller.update(queuedBytes: queue.reduce(0) { $0 + $1.totalBytes },
                              queuedMediaSeconds: Double(queue.count) * 2,
                              inFlightBytes: queue.first?.totalBytes ?? 0,
                              inFlightSeconds: queue.first?.startedAt.map { now - $0 } ?? 0,
                              now: now)
            maximumQueue = max(maximumQueue, queue.count)
            minimumRate = min(minimumRate, controller.targetBitrate)
            if step == 1200 { rateAtRecoveryStart = controller.targetBitrate }
            if now >= 100 && now < 120 { settledRates.append(controller.targetBitrate) }
            if now >= 120, fullRecoveryTime == nil, controller.targetBitrate == controller.maximumBitrate {
                fullRecoveryTime = now
            }
        }
        #expect(maximumQueue <= 5)
        #expect(minimumRate > controller.minimumBitrate)
        #expect(queue.count <= 1)
        #expect(rateAtRecoveryStart < controller.maximumBitrate)
        #expect(controller.targetBitrate == controller.maximumBitrate)
        #expect(fullRecoveryTime != nil && fullRecoveryTime! < 135)
        // A lasting drop must settle rather than continually recover into it.
        #expect(Double(settledRates.max()! - settledRates.min()!) / Double(settledRates.min()!) < 0.05)
    }
}
