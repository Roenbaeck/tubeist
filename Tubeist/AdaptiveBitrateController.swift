import Foundation

/// A segment-paced leaky-bucket controller, independent of capture and clocks
/// so network traces can be replayed deterministically in tests.
struct AdaptiveBitrateController: Sendable {
    struct Policy: Sendable {
        // This is an engineering allowance, NOT a reported YouTube buffer size.
        // YouTube's HLS ingestion API exposes acknowledgements, not buffer credit.
        var assumedRemoteBufferSeconds = 12.0
        var safetyReserveSeconds = 4.0
        var segmentSeconds = 2.0
        var normalDecreaseFraction = 0.20
        var wireOverhead = 1.08
    }

    enum State: String, Sendable {
        case steady, catchingUp, recovering, capacityBelowQualityFloor
    }

    let maximumBitrate: Int
    let minimumBitrate: Int
    let audioBitrate: Int
    let policy: Policy
    private(set) var targetBitrate: Int
    private(set) var state: State = .steady
    private(set) var estimatedThroughput: Double?
    private var lastEvaluation = -Double.infinity
    private var congestedObservations = 0
    private var deliverySamples: [Double] = []
    private var latestThroughput: Double?
    private var hasFreshDelivery = false

    init(maximumBitrate: Int, minimumBitrate: Int, audioBitrate: Int, policy: Policy = Policy()) {
        self.maximumBitrate = max(1, maximumBitrate)
        self.minimumBitrate = max(1, min(maximumBitrate, minimumBitrate))
        self.audioBitrate = max(0, audioBitrate)
        self.targetBitrate = max(1, maximumBitrate)
        self.policy = policy
    }

    mutating func delivered(bytes: Int, elapsed: Double) {
        guard bytes > 0, elapsed.isFinite, elapsed > 0 else { return }
        let throughput = Double(bytes) * 8 / max(0.001, elapsed)
        latestThroughput = throughput
        hasFreshDelivery = true
        deliverySamples.append(throughput)
        if deliverySamples.count > 5 { deliverySamples.removeFirst() }
        let sorted = deliverySamples.sorted()
        let median = sorted[sorted.count / 2]
        estimatedThroughput = estimatedThroughput.map { $0 * 0.7 + median * 0.3 } ?? median
    }

    /// Includes the full in-flight segment once, plus all waiting TS segments.
    /// An unfinished upload gives an optimistic throughput bound; this allows
    /// correcting an excessive initial preset before its first ACK arrives.
    mutating func update(
        queuedBytes: Int, queuedMediaSeconds: Double,
        inFlightBytes: Int, inFlightSeconds: Double, now: Double,
        pacedRecoverySeconds: Double? = nil
    ) {
        guard now.isFinite, now - lastEvaluation >= policy.segmentSeconds else { return }
        lastEvaluation = now
        let canRecover = hasFreshDelivery
        hasFreshDelivery = false
        // The median/EMA guards recovery against one unusually fast upload.
        // It must not hide a new slow upload when deciding whether to reduce.
        var capacity = estimatedThroughput.map { min($0, latestThroughput ?? $0) }
        let slowUploadThreshold = policy.segmentSeconds * 1.25
        if inFlightBytes > 0, inFlightSeconds > slowUploadThreshold {
            let upperBound = Double(inFlightBytes) * 8 / inFlightSeconds
            capacity = min(capacity ?? upperBound, upperBound)
        }
        guard let capacity, capacity.isFinite, capacity > 0 else { return }

        let wireRate = Double(targetBitrate + audioBitrate) * policy.wireOverhead
        // One segment normally exists while being uploaded; only the excess
        // constitutes backlog. Byte accounting follows bitrate changes exactly.
        let backlogBits = max(0, Double(queuedBytes) * 8 - wireRate * policy.segmentSeconds)
        let lag = max(0, queuedMediaSeconds - policy.segmentSeconds)
        let congested = lag >= 1 || inFlightSeconds > slowUploadThreshold
        let usableBuffer = max(policy.segmentSeconds * 2,
                               policy.assumedRemoteBufferSeconds - policy.safetyReserveSeconds)
        var catchUpSeconds = max(policy.segmentSeconds * 2, usableBuffer - lag)
        if let pacedRecoverySeconds, pacedRecoverySeconds.isFinite, pacedRecoverySeconds > 0 {
            // Share the pacer's remaining recovery horizon. A fresh recovery
            // is gentle; a missed target becomes urgent instead of perpetually
            // renewing a twenty-second allowance or imposing a four-second floor.
            catchUpSeconds = pacedRecoverySeconds
        }
        // Q' = R - C. To clear Q in T: R = C - Q/T. Reserve bandwidth for
        // audio, TS overhead, and encoder overshoot (AverageBitRate is soft).
        func sustainableVideoBitrate(at capacity: Double) -> Double {
            (capacity * 0.92 - backlogBits / catchUpSeconds) / policy.wireOverhead
                - Double(audioBitrate)
        }

        // Restore quality as soon as a completed upload supports it, including
        // while a backlog is draining. The latest sample caps the smoothed
        // estimate so old fast uploads cannot override a new slow one. Never
        // recover from an unfinished upload's optimistic bound alone, or reuse
        // a measurement from before the last reduction.
        if canRecover, let latestThroughput, inFlightSeconds <= slowUploadThreshold {
            let sustainable = sustainableVideoBitrate(at: min(capacity, latestThroughput))
            let desired = Int(max(0, min(Double(maximumBitrate), sustainable)))
            if desired > targetBitrate {
                targetBitrate = desired
                congestedObservations = 0
                state = desired == maximumBitrate ? .steady : .recovering
                return
            }
        }

        if congested {
            congestedObservations += 1
            let growth = max(0, 1 - capacity / max(1, wireRate))
            let timeToExhaustion = growth > 0 ? max(0, usableBuffer - lag) / growth : .infinity
            // Confirm congestion across two segment-spaced observations.
            // A completed slow upload plus an almost exhausted allowance is
            // enough evidence to act immediately; an in-flight bound alone is not.
            let urgent = timeToExhaustion <= policy.segmentSeconds * 3
            guard congestedObservations >= 2 || (urgent && canRecover) else { return }
            let sustainable = sustainableVideoBitrate(at: capacity)
            let desired = max(minimumBitrate, Int(max(0, min(Double(maximumBitrate), sustainable))))
            state = sustainable < Double(minimumBitrate) ? .capacityBelowQualityFloor : .catchingUp
            guard desired < targetBitrate else { return }
            let limited = Int(Double(targetBitrate) * (1 - policy.normalDecreaseFraction))
            targetBitrate = urgent ? desired : max(desired, limited)
        } else {
            congestedObservations = 0
            if targetBitrate == maximumBitrate {
                state = .steady
            } else if state != .capacityBelowQualityFloor {
                state = .recovering
            }
        }
    }
}
