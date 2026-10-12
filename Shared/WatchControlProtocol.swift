//
//  WatchControlProtocol.swift
//  Tubeist
//
//  The WCSession message vocabulary shared by the iPhone app and
//  TubeistWatch, so both sides agree on command/reply/state shapes without
//  duplicating them. Reuses the Live Activity's own phase/health/highlight
//  enums (StreamActivityAttributes.swift) rather than inventing parallel ones.
//

import Foundation

/// A command the Watch app sends to the iPhone app via
/// WCSession.sendMessage. The iPhone handles each by calling the exact same
/// code path its own UI buttons already use (Streamer.shared, 
/// HighlightRequestBridge) — there is only ever one implementation per
/// action, regardless of which surface triggered it.
enum WatchCommand: String, Codable, Sendable {
    case start
    case stop
    case saveHighlight

    static let key = "command"
    static let sessionIDKey = "sessionID"
}

struct WatchCommandReply: Codable, Sendable {
    var success: Bool
    var message: String?

    static let success = WatchCommandReply(success: true, message: nil)
    static func failure(_ message: String) -> WatchCommandReply {
        WatchCommandReply(success: false, message: message)
    }
}

/// Latest phone state, replaced atomically by WatchConnectivity application context.
/// External text is display data only; it never enters the command vocabulary.
struct WatchStateSnapshot: Codable, Sendable, Equatable {
    var generatedAt: Date = .distantPast
    var sessionID: UUID?
    var phase: StreamActivityPhase = .ended
    var startedAt: Date?
    var stoppedAt: Date?
    var health: StreamActivityHealth = .unknown
    var healthTracked = false
    var healthValidUntil: Date?
    var link: StreamActivityLink = .unknown
    var batteryPercent: Int?
    var canSaveHighlight = false
    var highlightStatus: HighlightStatus?
    var isAppActive = false
    var externalStatusConfigured = false
    var externalStatus: ExternalStatusSnapshot?
    var externalStatusRefreshFailed = false

    static let idle = WatchStateSnapshot()

    func isFresh(at now: Date) -> Bool {
        generatedAt <= now.addingTimeInterval(5) && now.timeIntervalSince(generatedAt) < 90
    }

    func hasSameContent(as other: Self) -> Bool {
        var copy = self
        copy.generatedAt = other.generatedAt
        return copy == other
    }

    /// Match the Live Activity's priorities: an upload failure must not be
    /// hidden by a good but delayed YouTube health sample.
    func healthIndicator(at now: Date) -> WatchHealthIndicator {
        guard isFresh(at: now) else { return .unknown }
        if phase == .failed { return .problem }
        guard phase == .streaming || phase == .recording else { return .unknown }
        if link == .failed { return .problem }
        let freshHealth = healthValidUntil.map { now < $0 } ?? false
        if healthTracked && freshHealth && health == .error { return .problem }
        if link == .degraded { return .warning }
        guard healthTracked else { return .untracked }
        guard freshHealth else { return .unknown }
        switch health {
        case .good: return link == .good ? .healthy : .unknown
        case .warning: return .warning
        case .error: return .problem
        case .waiting, .unknown: return .unknown
        }
    }
}

enum WatchHealthIndicator: Sendable {
    case unknown, untracked, healthy, warning, problem
}
