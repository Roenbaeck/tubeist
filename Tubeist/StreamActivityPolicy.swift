import Foundation

enum LiveActivityDetail: String, CaseIterable, Sendable {
    case off, standard, full
    var label: String { rawValue.capitalized }
}

struct StreamActivityPreferences: Equatable, Sendable {
    var detail: LiveActivityDetail = .standard
    var alerts = false
    var recoveryAlerts = false

    static var saved: Self {
        .init(detail: Settings.liveActivityDetail, alerts: Settings.liveActivityAlerts,
              recoveryAlerts: Settings.liveActivityRecoveryAlerts)
    }
}

/// Session identity and output choice are frozen independently of the Settings draft.
struct StreamActivitySession: Equatable, Sendable {
    let id: UUID
    let requestedAt: Date
    var startedAt: Date?
    var stoppedAt: Date?
    var streamsToYouTube: Bool
}

struct StreamActivitySnapshot: Equatable, Sendable {
    var session: StreamActivitySession
    var content: StreamActivityAttributes.ContentState
    var healthReceivedAt: Date?
    var remoteProblem = false
    var remoteHealthy = false
    var viewersTarget: YouTubeHealthTarget?
}

enum StreamActivityAlert: Equatable {
    case problem, recovered, stopped, test
    var title: String {
        switch self {
        case .problem: "Stream needs attention"
        case .recovered: "Stream health recovered"
        case .stopped: "Stream stopped unexpectedly"
        case .test: "Tubeist test alert"
        }
    }
    var body: String {
        switch self {
        case .problem: "Tubeist or YouTube reports a stream problem. Check Tubeist for details."
        case .recovered: "The stream problem has cleared. Check Tubeist for current status."
        case .stopped: "Open Tubeist to review the error before starting again."
        case .test: "This is a simulated alert. No YouTube stream was started."
        }
    }
}

/// Decisions depend on observations, not on counting the same cached poll twice.
struct StreamActivityPolicy {
    struct Decision {
        var content: StreamActivityAttributes.ContentState?
        var alert: StreamActivityAlert?
    }
    private var lastContent: StreamActivityAttributes.ContentState?
    private var lastPush: Date?
    private var lastObservation: Date?
    private var firstBadObservation: Date?
    private var badObservations = 0
    private var localFailureSince: Date?
    private var localRecoverySince: Date?
    private var activeAlert = false
    private var lastAlert: Date?
    private var reportedFailure = false

    mutating func evaluate(_ snapshot: StreamActivitySnapshot, preferences: StreamActivityPreferences, now: Date) -> Decision {
        let content = snapshot.content
        var alert: StreamActivityAlert?
        if preferences.alerts, preferences.detail != .off {
            if content.phase == .failed, !reportedFailure {
                reportedFailure = true
                alert = .stopped
            } else if content.phase == .streaming {
                alert = evaluateHealth(snapshot, recovery: preferences.recoveryAlerts, now: now)
            }
        } else {
            // Enabling alerts never inherits an earlier, unobserved alarm.
            firstBadObservation = nil
            badObservations = 0
            localFailureSince = nil
            localRecoverySince = nil
            activeAlert = false
        }
        let phaseChanged = content.phase != lastContent?.phase
        let due = lastPush.map { now.timeIntervalSince($0) >= 5 } ?? true
        let heartbeat = lastPush.map { now.timeIntervalSince($0) >= 60 } ?? true
        // A fresh but identical poll needn't synchronize a new payload. The next
        // meaningful update or heartbeat carries the latest expiry timestamp.
        var visibleContent = content
        visibleContent.healthValidUntil = lastContent?.healthValidUntil
        let changed = visibleContent != lastContent
        guard preferences.detail != .off,
              (changed && (due || phaseChanged)) || heartbeat || alert != nil else {
            return .init(content: nil, alert: nil)
        }
        lastContent = content
        lastPush = now
        return .init(content: content, alert: alert)
    }

    private mutating func evaluateHealth(_ snapshot: StreamActivitySnapshot, recovery: Bool, now: Date) -> StreamActivityAlert? {
        let content = snapshot.content
        let fresh = snapshot.healthReceivedAt.map { now.timeIntervalSince($0) <= 120 } ?? false
        if !fresh || !snapshot.remoteProblem {
            firstBadObservation = nil
            badObservations = 0
        }
        if fresh, let observed = snapshot.healthReceivedAt, observed != lastObservation {
            lastObservation = observed
            if snapshot.remoteProblem {
                firstBadObservation = firstBadObservation ?? observed
                badObservations += 1
            } else if snapshot.remoteHealthy, content.link == .good, activeAlert {
                activeAlert = false
                return recovery ? .recovered : nil
            }
        }
        if content.link == .failed {
            localFailureSince = localFailureSince ?? now
        } else {
            localFailureSince = nil
        }
        if !content.healthTracked, content.link == .good, activeAlert {
            localRecoverySince = localRecoverySince ?? now
            if now.timeIntervalSince(localRecoverySince ?? now) >= 10 {
                activeAlert = false
                localRecoverySince = nil
                return recovery ? .recovered : nil
            }
        } else {
            localRecoverySince = nil
        }
        let confirmedRemote = badObservations >= 2 && firstBadObservation.map {
            (snapshot.healthReceivedAt ?? now).timeIntervalSince($0) >= 10
        } == true
        let confirmedLocal = localFailureSince.map { now.timeIntervalSince($0) >= 10 } == true
        guard !activeAlert, confirmedRemote || confirmedLocal,
              lastAlert.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return nil }
        activeAlert = true
        lastAlert = now
        return .problem
    }
}

extension StreamActivityPolicy {
    mutating func resetPresentation() {
        lastContent = nil
        lastPush = nil
    }
}


struct StreamActivityRunKey: Equatable {
    let sessionID: UUID?
    let preferences: StreamActivityPreferences
}
