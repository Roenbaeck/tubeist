import Foundation

/// Immutable, derived settings. The selected bitrate is a ceiling, even below the quality floor.
struct BitrateLadder: Sendable, Hashable {
    let rungs: [Int] // Descending, unique; exact endpoints.
    var maximum: Int { rungs[0] }
    var minimum: Int { rungs[rungs.count - 1] }

    init(maximum: Int, minimum: Int) {
        let maximum = max(1, maximum)
        let minimum = max(1, min(maximum, minimum))
        var rungs = [maximum]
        var value = Double(maximum) * 0.8
        while value > Double(minimum) {
            let rounded = Int((value / 50_000).rounded()) * 50_000
            if rounded > minimum, rounded < rungs.last! { rungs.append(rounded) }
            value *= 0.8
        }
        if rungs.last != minimum { rungs.append(minimum) }
        self.rungs = rungs
    }

    func fitting(_ budget: Double) -> Int {
        rungs.first { Double($0) <= budget } ?? minimum
    }

    func next(above bitrate: Int) -> Int? { rungs.last { $0 > bitrate } }
}

/// Uses effective transaction throughput, not an estimate of YouTube's buffer.
/// All timestamps are monotonic and supplied by the caller for deterministic replay.
struct AdaptiveBitrateController: Sendable {
    struct Policy: Sendable {
        var segmentSeconds = 2.0
        var wireOverhead = 1.08
        var fastTimeConstant = 4.0
        var slowTimeConstant = 20.0
        var headroom = 0.85
        var drainSeconds = 6.0
        var pressureSeconds = 4.0
        var emergencySeconds = 8.0
        var restoreSeconds = 4.0
        var exploreSeconds = 10.0
        var provenSeconds = 20.0
        var provenExpirySeconds = 30.0
        var briefEpisodeSeconds = 6.0
        var failedIncreaseCooldown = 20.0
    }

    enum State: String, Sendable {
        case steady, catchingUp, recovering, capacityBelowQualityFloor
    }

    let ladder: BitrateLadder
    var maximumBitrate: Int { ladder.maximum }
    var minimumBitrate: Int { ladder.minimum }
    let audioBitrate: Int
    let policy: Policy
    private(set) var targetBitrate: Int
    private(set) var state: State = .steady
    private(set) var estimatedThroughput: Double?
    private(set) var fastThroughput: Double?
    private(set) var latestThroughput: Double?
    private var lastDeliveryAt: Double?
    private var freshDelivery = false
    private var slowDeliveries = 0
    private var lastMediaDuration = 2.0
    private var lastChange = -Double.infinity
    private var lastReduction = -Double.infinity
    private var lastObservedBacklog = 0.0
    private var episodeStartedAt: Double?
    private var lastEpisodeEndedAt = -Double.infinity
    private var briefRecovery = false
    private var stableSince: Double?
    private var provenBitrate: Int?
    private var provenAt = -Double.infinity
    private var increaseFrom: Int?
    private var increaseAt = -Double.infinity
    private var increasesBlockedUntil = -Double.infinity
    private var evidence: [(at: Double, capacity: Double)] = []

    init(maximumBitrate: Int, minimumBitrate: Int, audioBitrate: Int, policy: Policy = Policy()) {
        self.init(ladder: BitrateLadder(maximum: maximumBitrate, minimum: minimumBitrate),
                  audioBitrate: audioBitrate, policy: policy)
    }

    init(ladder: BitrateLadder, audioBitrate: Int, policy: Policy = Policy()) {
        self.ladder = ladder
        self.audioBitrate = max(0, audioBitrate)
        self.targetBitrate = ladder.maximum
        self.policy = policy
    }

    mutating func delivered(bytes: Int, elapsed: Double, mediaDuration: Double, now: Double) {
        guard bytes > 0, elapsed.isFinite, elapsed > 0, mediaDuration.isFinite, mediaDuration > 0,
              now.isFinite, lastDeliveryAt.map({ now > $0 }) ?? true else { return }
        let throughput = Double(bytes) * 8 / max(0.001, elapsed)
        // A burst contributes only the time actually passing. Idle periods cannot
        // give a single sample an entire history's weight, or count as good evidence.
        let dt = min(mediaDuration, lastDeliveryAt.map { now - $0 } ?? mediaDuration)
        if let lastDeliveryAt, now - lastDeliveryAt > max(5, mediaDuration * 2.5) {
            evidence.removeAll()
            stableSince = nil
        }
        func smooth(_ old: Double?, tau: Double) -> Double {
            let alpha = -expm1(-dt / tau)
            return old.map { $0 + alpha * (throughput - $0) } ?? throughput
        }
        fastThroughput = smooth(fastThroughput, tau: policy.fastTimeConstant)
        estimatedThroughput = smooth(estimatedThroughput, tau: policy.slowTimeConstant)
        latestThroughput = throughput
        lastDeliveryAt = now
        freshDelivery = true
        lastMediaDuration = mediaDuration
        slowDeliveries = elapsed > mediaDuration * 1.25 ? slowDeliveries + 1 : 0
    }

    /// Waiting work excludes the current transaction. Called on arrivals, ACKs and
    /// encoder boundaries. Only delivered() supplies evidence for an increase.
    mutating func update(waitingBytes: Int, waitingMediaSeconds: Double,
                         inFlightBytes: Int, inFlightDuration: Double, inFlightSeconds: Double, now: Double) {
        guard now.isFinite, waitingBytes >= 0, waitingMediaSeconds.isFinite, waitingMediaSeconds >= 0,
              inFlightBytes >= 0, inFlightDuration.isFinite, inFlightDuration >= 0,
              inFlightSeconds.isFinite, inFlightSeconds >= 0 else { return }
        let fresh = freshDelivery
        freshDelivery = false
        let stalled = inFlightBytes > 0 && inFlightSeconds > max(0.1, inFlightDuration) * 1.25
        let pressure = waitingMediaSeconds >= policy.pressureSeconds
        let behind = stalled || pressure || (fresh && (waitingMediaSeconds > 0 || slowDeliveries > 0))
        if behind {
            if episodeStartedAt == nil {
                episodeStartedAt = now
                // Recurrent congestion disables optimistic restoration.
                briefRecovery = now - lastEpisodeEndedAt >= policy.failedIncreaseCooldown
            }
            evidence.removeAll()
            stableSince = nil
        }
        if let start = episodeStartedAt, now - start > policy.briefEpisodeSeconds { briefRecovery = false }

        var capacity = latestThroughput.flatMap { last in fastThroughput.map { min(last, $0) } }
        if stalled {
            // Total bytes / elapsed is only an optimistic upper bound until ACK.
            // It can justify cuts, never recovery, even before the first successful upload.
            let bound = Double(inFlightBytes) * 8 / inFlightSeconds
            capacity = min(capacity ?? bound, bound)
        }
        let emergency = waitingMediaSeconds >= policy.emergencySeconds
        let backlogGrowing = waitingMediaSeconds >= lastObservedBacklog - 0.001
        if fresh { lastObservedBacklog = waitingMediaSeconds }
        // Give a change two segment intervals to reach completed media. Old large
        // segments may still be draining; do not ratchet down just because they exist.
        let settled = now - lastChange >= 2 * max(policy.segmentSeconds, lastMediaDuration)
        let stalledLongEnough = stalled && waitingMediaSeconds > 0
        let reductionNeeded = slowDeliveries >= 2 || stalledLongEnough || pressure
        if let capacity, reductionNeeded, (settled || emergency),
           (fresh || stalled), (backlogGrowing || stalled || slowDeliveries >= 2) {
            let budget = (policy.headroom * capacity - Double(waitingBytes) * 8 / policy.drainSeconds)
                / policy.wireOverhead - Double(audioBitrate)
            var desired = ladder.fitting(budget)
            if let prior = increaseFrom, now - increaseAt < policy.failedIncreaseCooldown {
                desired = min(desired, prior)
                increasesBlockedUntil = now + policy.failedIncreaseCooldown
                briefRecovery = false
                provenBitrate = nil
            }
            if desired < targetBitrate {
                targetBitrate = desired
                lastChange = now
                lastReduction = now
                evidence.removeAll()
                stableSince = nil
                increaseFrom = nil
            }
            state = budget < Double(minimumBitrate) ? .capacityBelowQualityFloor : .catchingUp
        }

        // Only a successful final ACK proves the queue drained. Ordinary arrivals
        // and an unfinished request can never authorize a raise.
        guard fresh, waitingMediaSeconds == 0, inFlightBytes == 0, slowDeliveries == 0,
              let latestThroughput, let fastThroughput, let estimatedThroughput else { return }
        if episodeStartedAt != nil {
            episodeStartedAt = nil
            lastEpisodeEndedAt = now
            evidence.removeAll()
        }
        let sustainable = policy.headroom * min(latestThroughput, fastThroughput) / policy.wireOverhead
            - Double(audioBitrate)
        state = targetBitrate == minimumBitrate && sustainable < Double(minimumBitrate)
            ? .capacityBelowQualityFloor : (targetBitrate == maximumBitrate ? .steady : .recovering)
        evidence.append((now, latestThroughput))
        evidence.removeAll { now - $0.at > policy.exploreSeconds + 2 * policy.segmentSeconds }
        // Also bound storage for unusually tiny, quickly acknowledged segments.
        if evidence.count > 128 { evidence.removeFirst(evidence.count - 128) }

        if latestThroughput >= wireRate(targetBitrate) * 1.25 {
            if stableSince == nil { stableSince = now }
            if now - stableSince! >= policy.provenSeconds {
                provenBitrate = targetBitrate
                provenAt = now
            }
        } else { stableSince = nil }
        guard now >= increasesBlockedUntil, now - lastChange >= policy.restoreSeconds,
              let next = ladder.next(above: targetBitrate) else { return }

        func supported(_ candidate: Int, seconds: Double, margin: Double) -> Bool {
            let needed = wireRate(candidate) * margin
            // A bad sample resets the sustained-evidence interval for this rung.
            let suffix = evidence.reversed().prefix { $0.capacity >= needed && $0.at > lastReduction }
            return suffix.count >= 3 && now - (suffix.last?.at ?? now) >= seconds
        }
        var desired: Int?
        if briefRecovery, let provenBitrate, now - provenAt <= policy.provenExpirySeconds {
            desired = ladder.rungs.first {
                $0 > targetBitrate && $0 <= provenBitrate && fastThroughput >= wireRate($0) * 1.25
                    && supported($0, seconds: policy.restoreSeconds, margin: 1.25)
            }
        }
        if desired == nil, min(fastThroughput, estimatedThroughput) >= wireRate(next) * 1.3,
           supported(next, seconds: policy.exploreSeconds, margin: 1.3) {
            desired = next
        }
        if let desired {
            increaseFrom = targetBitrate
            increaseAt = now
            targetBitrate = desired
            lastChange = now
            stableSince = nil
            evidence.removeAll()
            state = desired == maximumBitrate ? .steady : .recovering
        }
    }

    mutating func discardedBacklog(now: Double) {
        guard now.isFinite else { return }
        targetBitrate = minimumBitrate
        state = .catchingUp
        lastChange = now
        lastReduction = now
        increasesBlockedUntil = now + policy.failedIncreaseCooldown
        episodeStartedAt = now
        briefRecovery = false
        provenBitrate = nil
        stableSince = nil
        evidence.removeAll()
        freshDelivery = false
        increaseFrom = nil
    }

    private func wireRate(_ video: Int) -> Double {
        (Double(video) + Double(audioBitrate)) * policy.wireOverhead
    }
}
