//
//  StreamActivityPolicy.swift
//  Tubeist
//
//  Pure decision logic for the watch Live Activity: which fields to show for a
//  detail level, update throttling, stale detection and the Bad/NoData alert
//  state machine. No ActivityKit or UIKit dependencies, so it is unit-tested.
//

import Foundation

enum LiveActivityDetail: String, CaseIterable, Sendable {
    case off, standard, full

    var label: String {
        switch self {
        case .off: "Off"
        case .standard: "Standard"
        case .full: "Full"
        }
    }
}

struct StreamSnapshot: Equatable, Sendable {
    var phase: StreamPhase
    var youtubeHealth: YouTubeStreamHealth
    /// False when nothing is polling health (no bound YouTube stream id), so the
    /// absence of a reading is expected rather than a problem.
    var healthTracked: Bool = true
    /// When `youtubeHealth` was last fetched successfully; nil = never.
    var healthUpdatedAt: Date?
    var viewers: Int?
    var bitrateKbps: Int?
    var link: LinkQuality
    var thermal: ThermalLevel
    var batteryPercent: Int?
    var warning: String?
    var youtubeStatusLabel: String? = nil
}

enum StreamAlert: Equatable, Sendable {
    case degraded(YouTubeStreamHealth)
    case recovered
    case highlightSaved
    case highlightFailed(String)

    var title: String {
        switch self {
        case .degraded(let health): "Stream health: \(health.label)"
        case .recovered: "Stream health recovered"
        case .highlightSaved: "Highlight saved"
        case .highlightFailed: "Highlight not saved"
        }
    }

    var body: String {
        switch self {
        case .degraded(.noData): "YouTube is receiving no data from your stream."
        case .degraded: "YouTube reports problems with your stream."
        case .recovered: "YouTube reports your stream is healthy again."
        case .highlightSaved: "The moment was saved as a local clip."
        case .highlightFailed(let message): message
        }
    }
}

struct StreamActivityPolicy {
    static let updateInterval: TimeInterval = 5
    static let staleAfter: TimeInterval = 60
    static let alertDebounce: TimeInterval = 10
    static let alertCooldown: TimeInterval = 60
    /// A healthy stream's content stops changing, but every push renews the
    /// activity's 90 s stale date, so an unchanged activity must still be pushed
    /// periodically or iOS dims a perfectly healthy Live Activity.
    static let heartbeatInterval: TimeInterval = 60

    struct Decision: Equatable {
        /// nil = do not touch the Live Activity (off, or throttled).
        var content: StreamActivityAttributes.ContentState?
        var alert: StreamAlert?
    }

    var detail: LiveActivityDetail
    var alertOnBad: Bool
    var alertOnRecovery: Bool

    private var lastPushed: StreamActivityAttributes.ContentState?
    private var lastPushedAt: Date?
    private var badSince: Date?
    private var alertActive = false
    private var lastAlertAt: Date?

    init(detail: LiveActivityDetail, alertOnBad: Bool, alertOnRecovery: Bool) {
        self.detail = detail
        self.alertOnBad = alertOnBad
        self.alertOnRecovery = alertOnRecovery
    }

    mutating func evaluate(_ snapshot: StreamSnapshot, now: Date, forceContent: Bool = false) -> Decision {
        // Untracked health is not missing health: there is nothing to poll, so it can
        // neither go stale nor raise an alert.
        let stale = snapshot.healthTracked
            ? snapshot.healthUpdatedAt.map { now.timeIntervalSince($0) > Self.staleAfter } ?? true
            : false
        let alert = snapshot.healthTracked
            ? nextAlert(health: snapshot.youtubeHealth, stale: stale, now: now)
            : nil

        var content: StreamActivityAttributes.ContentState?
        if detail != .off {
            let candidate = makeContent(snapshot, stale: stale)
            let phaseChanged = candidate.phase != lastPushed?.phase
            let due = lastPushedAt.map { now.timeIntervalSince($0) >= Self.updateInterval } ?? true
            let changed = candidate != lastPushed
            // The heartbeat re-arms the activity's stale date on a stream whose content
            // never changes; without it a healthy Standard activity goes stale at 90 s.
            let heartbeat = lastPushedAt.map { now.timeIntervalSince($0) >= Self.heartbeatInterval } ?? true
            if (changed && (due || phaseChanged)) || heartbeat || alert != nil || forceContent {
                content = candidate
                lastPushed = candidate
                lastPushedAt = now
            }
        }
        return Decision(content: content, alert: alert)
    }

    private func makeContent(
        _ snapshot: StreamSnapshot,
        stale: Bool
    ) -> StreamActivityAttributes.ContentState {
        let full = detail == .full
        return StreamActivityAttributes.ContentState(
            phase: snapshot.phase,
            health: snapshot.healthTracked ? snapshot.youtubeHealth : .unknown,
            healthTracked: snapshot.healthTracked,
            isStale: stale,
            warning: snapshot.warning,
            viewers: full ? snapshot.viewers : nil,
            bitrateKbps: full ? snapshot.bitrateKbps : nil,
            link: full ? snapshot.link : nil,
            thermal: full ? snapshot.thermal : nil,
            batteryPercent: full ? snapshot.batteryPercent : nil,
            youtubeStatusLabel: snapshot.youtubeStatusLabel
        )
    }

    private mutating func nextAlert(
        health: YouTubeStreamHealth,
        stale: Bool,
        now: Date
    ) -> StreamAlert? {
        // A stale gap means nothing is known about the stream, so a bad reading after
        // it starts the debounce over rather than continuing a count from before it.
        guard !stale else {
            badSince = nil
            return nil
        }

        if health.isAlarming {
            guard alertOnBad else { return nil }
            let since = badSince ?? now
            badSince = since
            guard !alertActive,
                  now.timeIntervalSince(since) >= Self.alertDebounce else { return nil }
            if let last = lastAlertAt, now.timeIntervalSince(last) < Self.alertCooldown {
                return nil
            }
            alertActive = true
            lastAlertAt = now
            return .degraded(health)
        }

        badSince = nil
        guard alertActive, health != .unknown else { return nil }
        alertActive = false
        return alertOnRecovery ? .recovered : nil
    }
}
