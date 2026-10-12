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
}

struct WatchCommandReply: Codable, Sendable {
    var success: Bool
    var message: String?

    static let success = WatchCommandReply(success: true, message: nil)
    static func failure(_ message: String) -> WatchCommandReply {
        WatchCommandReply(success: false, message: message)
    }
}

/// Pushed iPhone -> Watch via WCSession.updateApplicationContext, mirroring
/// the same state StreamActivityCoordinator already turns into the Live
/// Activity's ContentState.
struct WatchStateSnapshot: Codable, Sendable, Equatable {
    var phase: StreamActivityPhase
    var startedAt: Date?
    var health: StreamActivityHealth
    var healthTracked: Bool
    var batteryPercent: Int?
    var canSaveHighlight: Bool
    var highlightStatus: HighlightStatus?
    /// Whether the iPhone app is currently in the foreground. Starting a
    /// stream needs the app active (camera/mic setup, YouTube broadcast
    /// creation aren't things a backgrounded app should kick off from a
    /// Watch tap), so the Watch uses this — not WCSession.isReachable, which
    /// can stay true for a backgrounded-but-not-terminated app — to decide
    /// whether to show Start at all.
    var isAppActive: Bool
    /// Whether a Score API URL is set in Settings at all — independent of
    /// `scoreboard` below, so the Watch can hide the whole score section
    /// rather than show a placeholder when the feature is simply unused.
    var scoreboardConfigured: Bool
    /// nil while a Score API is configured but not actively streaming
    /// (WatchSessionManager only polls it then), or before the first poll
    /// completes.
    var scoreboard: WatchScoreSnapshot?

    static let idle = WatchStateSnapshot(
        phase: .ended,
        startedAt: nil,
        health: .unknown,
        healthTracked: false,
        batteryPercent: nil,
        canSaveHighlight: false,
        highlightStatus: nil,
        isAppActive: false,
        scoreboardConfigured: false,
        scoreboard: nil
    )
}

/// Live score, sourced from a self-hosted scoreboard server
/// (github.com/Lindhardsen/scoreboard) via WatchSessionManager's polling.
struct WatchScoreSnapshot: Codable, Sendable, Equatable {
    var teamA: String
    var teamB: String
    var setsA: Int
    var setsB: Int
    var pointsA: Int
    var pointsB: Int
}
