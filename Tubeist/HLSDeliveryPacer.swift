import Foundation

/// Minimum media rate for a fixed local recovery deadline, using Q' = 1 - r.
/// This is a fluid queue model, not knowledge of YouTube's playable buffer.
struct HLSDeliveryPacer: Sendable {
    struct Policy: Sendable {
        var recoverySeconds = 20.0
        // Refill the receiver promptly after a stall, then return to pacing.
        // This is a bounded count of serialized uploads, not parallel requests.
        var immediateRecoverySegments = 2
        // Leave space for two maximum-duration HLS segments while waiting.
        let queueReserveSeconds = 10.0
        let queueReserveFragments = 2
    }

    struct Decision: Sendable {
        enum Reason: String, Sendable {
            case steady, recoveryBurst, recovering, recoveryDeadline, queuePressure, shutdownDeadline, invalidObservation
        }
        /// nil means work-conserving delivery: no deliberate wait.
        let rate: Double?
        let delay: TimeInterval
        let reason: Reason
    }

    let policy: Policy
    private var lastStartedAt: TimeInterval?
    private var lastDuration = 0.0
    private var recoveryDeadline: TimeInterval?
    private var immediateRecoverySegmentsRemaining = 0
    private var awaitingFreshMedia = true

    init(policy: Policy = Policy()) {
        self.policy = policy
    }

    mutating func decision(
        queuedMediaSeconds: Double, nextDuration: Double, now: TimeInterval,
        queuedFragments: Int = 1, maximumQueuedDuration: Double = 60,
        maximumQueuedFragments: Int = 30, finishBy: TimeInterval? = nil
    ) -> Decision {
        guard queuedMediaSeconds.isFinite, queuedMediaSeconds >= 0,
              nextDuration.isFinite, nextDuration >= 0, now.isFinite,
              maximumQueuedDuration.isFinite, maximumQueuedDuration > 0,
              queuedFragments >= 0, maximumQueuedFragments > 0,
              finishBy.map({ $0.isFinite }) ?? true else {
            return Decision(rate: nil, delay: 0, reason: .invalidObservation)
        }
        // A fresh segment after an idle period is normal. A segment still
        // waiting when the preceding upload finishes is backlog, even if it
        // is the only one left. Only becameIdle() confirms that recovery ended.
        if recoveryDeadline == nil, queuedMediaSeconds > 0,
           !awaitingFreshMedia || queuedMediaSeconds > nextDuration {
            recoveryDeadline = now + policy.recoverySeconds
            immediateRecoverySegmentsRemaining = max(0, policy.immediateRecoverySegments)
        }
        if queuedMediaSeconds >= maximumQueuedDuration - policy.queueReserveSeconds ||
            queuedFragments >= maximumQueuedFragments - policy.queueReserveFragments {
            return Decision(rate: nil, delay: 0, reason: .queuePressure)
        }
        let remaining = recoveryTimeRemaining(at: now)
        if let remaining, remaining <= 0 {
            return Decision(rate: nil, delay: 0, reason: .recoveryDeadline)
        }
        if immediateRecoverySegmentsRemaining > 0 {
            return Decision(rate: nil, delay: 0, reason: .recoveryBurst)
        }
        // T is remaining time to the ORIGINAL deadline, not a new horizon.
        // Q includes ALL waiting media, including the next upload. Subtracting
        // that segment strands one segment at 1x indefinitely. There is no
        // hard 2x cap; r = 1 + Q/T clears Q while arrivals continue at 1x.
        let rate = remaining.map { 1 + queuedMediaSeconds / $0 } ?? 1
        let reason: Decision.Reason = remaining == nil ? .steady : .recovering
        var delay = 0.0
        if let lastStartedAt, now >= lastStartedAt {
            // Actual transfer time consumes spacing. An outage never builds
            // credit for a later burst against an obsolete ideal schedule.
            delay = max(0, lastStartedAt + lastDuration / rate - now)
        }
        if let finishBy {
            // Preserve enough time to drain remaining media at real time.
            // Once that slack is gone, pacing yields to the Stop deadline.
            let slack = finishBy - now - queuedMediaSeconds
            if slack <= delay {
                return Decision(rate: nil, delay: 0, reason: .shutdownDeadline)
            }
        }
        return Decision(rate: rate, delay: delay, reason: reason)
    }

    func recoveryTimeRemaining(at now: TimeInterval) -> TimeInterval? {
        recoveryDeadline.map { max(0, $0 - now) }
    }

    mutating func becameIdle() {
        if recoveryDeadline != nil {
            // Recovery has actually drained through the final ACK. Rebase on
            // the next fresh arrival rather than preserving the old delayed
            // phase with artificial waits. Never reset while work remains.
            lastStartedAt = nil
            lastDuration = 0
        }
        recoveryDeadline = nil
        immediateRecoverySegmentsRemaining = 0
        awaitingFreshMedia = true
    }

    mutating func beganUpload(duration: Double, now: TimeInterval) {
        guard duration.isFinite, duration >= 0, now.isFinite else { return }
        awaitingFreshMedia = false
        // Only actual uploads consume the allowance. Repeated decisions,
        // interrupted waits and new arrivals cannot renew a recovery burst.
        if immediateRecoverySegmentsRemaining > 0 { immediateRecoverySegmentsRemaining -= 1 }
        lastStartedAt = now
        lastDuration = duration
    }
}
