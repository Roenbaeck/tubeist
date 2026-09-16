import Foundation

/// Minimum media rate for a fixed local recovery deadline, using Q' = 1 - r.
/// This is a fluid queue model, not knowledge of YouTube's playable buffer.
struct HLSDeliveryPacer: Sendable {
    struct Policy: Sendable {
        let recoverySeconds = 20.0
        // Leave space for two maximum-duration HLS segments while waiting.
        let queueReserveSeconds = 10.0
        let queueReserveFragments = 2
    }

    struct Decision: Sendable {
        enum Reason: String, Sendable {
            case steady, recovering, recoveryDeadline, queuePressure, shutdownDeadline, invalidObservation
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
        // One ready segment is normal; only the material behind it is backlog.
        let backlog = max(0, queuedMediaSeconds - max(0, nextDuration))
        if backlog == 0 {
            recoveryDeadline = nil
        } else if recoveryDeadline == nil {
            recoveryDeadline = now + policy.recoverySeconds
        }
        if queuedMediaSeconds >= maximumQueuedDuration - policy.queueReserveSeconds ||
            queuedFragments >= maximumQueuedFragments - policy.queueReserveFragments {
            return Decision(rate: nil, delay: 0, reason: .queuePressure)
        }
        let remaining = recoveryTimeRemaining(at: now)
        if let remaining, remaining <= 0 {
            return Decision(rate: nil, delay: 0, reason: .recoveryDeadline)
        }
        // T is remaining time to the ORIGINAL deadline, not a new horizon.
        // r = 1 + Q/T is the least constant service rate that clears Q in T
        // while arrivals continue at 1x. There is deliberately no hard 2x cap.
        let rate = remaining.map { 1 + backlog / $0 } ?? 1
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
        recoveryDeadline = nil
    }

    mutating func beganUpload(duration: Double, now: TimeInterval) {
        guard duration.isFinite, duration >= 0, now.isFinite else { return }
        lastStartedAt = now
        lastDuration = duration
    }
}
