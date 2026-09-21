import Foundation

/// Observation owned by Stop, independent of the live-view health task.
/// Two inactive polls after ENDLIST are a completion heuristic, not proof that
/// YouTube has processed the last frame.
@MainActor
final class YouTubeShutdownMonitor {
    typealias FetchBroadcast = @MainActor (YouTubeHealthTarget) async throws -> String?
    static let pollingInterval: Duration = .seconds(5)

    private(set) var observedCompletion = false
    private(set) var consecutiveInactivePolls = 0
    var canCompleteEarly: Bool { observedCompletion || consecutiveInactivePolls >= 2 }
    private let stoppedAt: ContinuousClock.Instant
    private var endListAcknowledgedAt: ContinuousClock.Instant?
    private let now: () -> ContinuousClock.Instant
    private let log: (String, LogLevel) -> Void

    init(stoppedAt: ContinuousClock.Instant,
         now: @escaping () -> ContinuousClock.Instant = { .now },
         log: @escaping (String, LogLevel) -> Void = { LOG($0, level: $1) }) {
        self.stoppedAt = stoppedAt
        self.now = now
        self.log = log
    }

    func endListAcknowledged() {
        guard endListAcknowledgedAt == nil else { return }
        endListAcknowledgedAt = now()
        consecutiveInactivePolls = 0
        event("ENDLIST acknowledged; waiting for two consecutive inactive polls, or 120 seconds, before requesting completion", level: .info)
    }

    func event(_ message: String, level: LogLevel = .debug) {
        let instant = now()
        var timing = "Stop +\(seconds(from: stoppedAt, to: instant))s"
        if let endListAcknowledgedAt {
            timing += "; ENDLIST +\(seconds(from: endListAcknowledgedAt, to: instant))s"
        }
        // Elapsed time preserves each poll in the log's repeat-coalescing store.
        log("YouTube shutdown [\(timing)]: \(message)", level)
    }

    func run(target: YouTubeHealthTarget,
             fetchHealth: YouTubeStreamHealthMonitor.Fetch,
             fetchBroadcast: FetchBroadcast,
             sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async {
        while !Task.isCancelled {
            await refresh(target: target, fetchHealth: fetchHealth, fetchBroadcast: fetchBroadcast)
            do { try await sleep(Self.pollingInterval) }
            catch { return }
        }
    }

    func refresh(target: YouTubeHealthTarget,
                 fetchHealth: YouTubeStreamHealthMonitor.Fetch,
                 fetchBroadcast: FetchBroadcast) async {
        guard !Task.isCancelled else { return }
        // A request begun before ENDLIST may return stale inactivity after its
        // acknowledgement. Only post-acknowledgement requests count.
        let isPostEndListPoll = endListAcknowledgedAt != nil
        do {
            let report = try await fetchHealth(target)
            try Task.checkCancellation()
            let updated = report.healthStatus?.lastUpdateTimeSeconds.map { String(format: "%.0f", $0) } ?? "unavailable"
            let issues = report.healthStatus?.configurationIssues ?? []
            event("stream=\(report.streamStatus ?? "unknown"); health=\(report.healthStatus?.status ?? "unknown"); updated=\(updated); issues=\(issues.count)")
            for issue in issues { event("issue: \(issue.diagnostic)") }
            if isPostEndListPoll {
                consecutiveInactivePolls = report.streamStatus == "inactive"
                    ? consecutiveInactivePolls + 1 : 0
                if consecutiveInactivePolls == 2 {
                    event("Two consecutive inactive polls after ENDLIST; ready to request broadcast completion", level: .info)
                }
            }
        } catch {
            guard !Task.isCancelled, !YouTubeDiagnostics.isCancellation(error) else { return }
            consecutiveInactivePolls = 0
            event("Health lookup unavailable (\(YouTubeDiagnostics.failure(error)))", level: .warning)
        }
        // A health lookup failure must not hide an independently available
        // broadcast status. Both requests stay pinned to the session's account.
        guard !Task.isCancelled else { return }
        do {
            let status = try await fetchBroadcast(target)
            try Task.checkCancellation()
            event("broadcast=\(status ?? "unknown")")
            if status == "complete", !observedCompletion {
                observedCompletion = true
                event("YouTube completed the broadcast without a Tubeist completion request", level: .info)
            }
        } catch {
            guard !Task.isCancelled, !YouTubeDiagnostics.isCancellation(error) else { return }
            event("Broadcast lookup unavailable (\(YouTubeDiagnostics.failure(error)))", level: .warning)
        }
    }

    private func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> String {
        let duration = start.duration(to: end).components
        let value = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
