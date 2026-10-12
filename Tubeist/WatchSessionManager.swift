//
//  WatchSessionManager.swift
//  Tubeist
//
//  iPhone-side WatchConnectivity handler. Every command from TubeistWatch
//  runs through the exact same entry points the phone UI's own buttons
//  already use (Streamer.shared, HighlightRequestBridge) — there is only
//  ever one implementation per action, regardless of trigger source — and
//  periodically mirrors the same state the Live Activity shows.
//

import Foundation
import UIKit
import WatchConnectivity

/// Decodes the scoreboard server's GET /<username>/api/score response
/// (github.com/Lindhardsen/scoreboard). Kept private to this file since it's
/// purely a wire-format detail of talking to that server — WatchScoreSnapshot
/// in Shared/WatchControlProtocol.swift is the stable iPhone<->Watch shape.
private struct ScoreboardServerResponse: Decodable {
    struct Team: Decodable {
        var name: String
        var sets: Int
        var points: Int
    }
    var home: Team
    var away: Team
    var matchEnded: Bool

    var snapshot: WatchScoreSnapshot {
        WatchScoreSnapshot(
            teamA: home.name, teamB: away.name,
            setsA: home.sets, setsB: away.sets,
            pointsA: home.points, pointsB: away.points
        )
    }
}

@MainActor
final class WatchSessionManager: NSObject, WCSessionDelegate {
    static let shared = WatchSessionManager()

    private nonisolated static let payloadKey = "payload"
    private static let pushInterval: Duration = .seconds(2)
    private static let scoreboardPollInterval: Duration = .seconds(5)

    var appState: AppState?
    private var pushTask: Task<Void, Never>?
    private var lastPushedSnapshot: WatchStateSnapshot?
    private var scoreboardPollTask: Task<Void, Never>?
    private var latestScoreboard: WatchScoreSnapshot?

    func start(appState: AppState) {
        self.appState = appState
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        startPushLoop()
        startScoreboardPollLoop()
        observeAppLifecycle()
    }

    /// Pushes immediately on a foreground/background transition rather than
    /// waiting for the next pushLoop tick, since the Watch's Start button
    /// gates on isAppActive and backgrounding can happen right before the
    /// app gets suspended (and the loop with it).
    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        for name: Notification.Name in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.pushStateIfNeeded()
                }
            }
        }
    }

    private func startPushLoop() {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pushStateIfNeeded()
                try? await Task.sleep(for: Self.pushInterval)
            }
        }
    }

    /// Separate from the push loop above since this does real network I/O
    /// with its own cadence and failure handling, unlike the local-state-only
    /// snapshot push. Deliberately limited to while actively streaming and
    /// in the foreground — per-user request, and it also matches what iOS
    /// would allow by default anyway: ordinary background execution gets
    /// suspended within seconds, so an indefinite background poll loop
    /// wouldn't actually keep running without extra entitlements this
    /// feature doesn't need.
    private func startScoreboardPollLoop() {
        scoreboardPollTask?.cancel()
        scoreboardPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollScoreboardIfNeeded()
                try? await Task.sleep(for: Self.scoreboardPollInterval)
            }
        }
    }

    private func pollScoreboardIfNeeded() async {
        guard let appState, appState.isStreamActive,
              UIApplication.shared.applicationState == .active,
              let url = Self.scoreboardScoreURL() else {
            latestScoreboard = nil
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            latestScoreboard = try JSONDecoder().decode(ScoreboardServerResponse.self, from: data).snapshot
        } catch {
            // Keep showing the last known score rather than flicker it away
            // on one transient failure (the scraper itself may be between
            // polls, or the network hiccuped).
            LOG("Could not fetch scoreboard score: \(error.localizedDescription)", level: .debug)
        }
    }

    private static func scoreboardScoreURL() -> URL? {
        let base = Settings.scoreboardAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(trimmedBase)/api/score")
    }

    private func pushStateIfNeeded() {
        guard let appState, WCSession.default.activationState == .activated else { return }
        let snapshot = currentSnapshot(appState: appState)
        guard snapshot != lastPushedSnapshot else { return }
        do {
            let data = try PropertyListEncoder().encode(snapshot)
            try WCSession.default.updateApplicationContext([Self.payloadKey: data])
            lastPushedSnapshot = snapshot
        } catch {
            LOG("Could not push Watch state: \(error.localizedDescription)", level: .debug)
        }
    }

    private func currentSnapshot(appState: AppState) -> WatchStateSnapshot {
        guard let activity = appState.activitySnapshot(preferences: appState.activityPreferences) else {
            // .idle's isAppActive/scoreboardConfigured are placeholders;
            // those two are meaningful even with no activity session yet
            // (e.g. app open but nothing started), so fill in the real values.
            var idle = WatchStateSnapshot.idle
            idle.isAppActive = UIApplication.shared.applicationState == .active
            idle.scoreboardConfigured = Self.scoreboardScoreURL() != nil
            return idle
        }
        let content = activity.content
        return WatchStateSnapshot(
            phase: content.phase,
            startedAt: content.startedAt,
            health: content.health,
            healthTracked: content.healthTracked,
            batteryPercent: content.batteryPercent,
            canSaveHighlight: content.canSaveHighlight,
            highlightStatus: content.highlightStatus,
            isAppActive: UIApplication.shared.applicationState == .active,
            scoreboardConfigured: Self.scoreboardScoreURL() != nil,
            scoreboard: latestScoreboard
        )
    }

    // MARK: - WCSessionDelegate
    // Apple calls these on a background thread, so none of them are
    // MainActor-isolated; each hops over explicitly where needed.

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            LOG("Watch session activation failed: \(error.localizedDescription)", level: .warning)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// [String: Any] and the raw replyHandler aren't Sendable (WatchConnectivity
    /// predates Swift concurrency) — the Data payload is extracted up front
    /// since Data is Sendable, and the handler is boxed the same way other
    /// non-Sendable system callbacks are boxed elsewhere in this codebase
    /// (e.g. SendableAssetWriterFinishHandle in RecordingAssetWriter.swift).
    private struct SendableReplyHandler: @unchecked Sendable {
        let handler: ([String: Any]) -> Void
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        // WatchCommand has no associated data, so it travels as a plain
        // string under its own key — PropertyListEncoder refuses to encode
        // a bare top-level enum, since a plist's root must be a container.
        let rawCommand = message[WatchCommand.key] as? String
        let boxedReply = SendableReplyHandler(handler: replyHandler)
        Task { @MainActor in
            let reply = await self.handle(rawCommand: rawCommand)
            let data = (try? PropertyListEncoder().encode(reply)) ?? Data()
            boxedReply.handler([Self.payloadKey: data])
        }
    }

    func handle(rawCommand: String?) async -> WatchCommandReply {
        guard let rawCommand, let command = WatchCommand(rawValue: rawCommand) else {
            return .failure("Unrecognized command")
        }
        guard let appState else { return .failure("Tubeist is not ready") }
        switch command {
        case .start: return await handleStart(appState: appState)
        case .stop: return await handleStop(appState: appState)
        case .saveHighlight: return await handleSaveHighlight(appState: appState)
        }
    }

    /// Deliberately does not re-check camera readiness/permissions the way
    /// the phone UI's button does — Streamer.shared.startStream already
    /// throws a descriptive error (e.g. CaptureSetupError) when the capture
    /// pipeline isn't ready, so that stays the single source of truth rather
    /// than duplicating the check here.
    ///
    /// Replies as soon as the command is accepted rather than awaiting the
    /// full operation — starting/stopping a stream (camera warm-up, YouTube
    /// broadcast setup) routinely takes longer than WCSession's reply window,
    /// which produces WCError.messageReplyTimedOut if awaited here. The
    /// phone's own UI button follows the same fire-and-forget shape; the
    /// Watch learns the real outcome from the periodic WatchStateSnapshot
    /// push (phase/activeAlert) instead of the message reply.
    private func handleStart(appState: AppState) async -> WatchCommandReply {
        if appState.youtubeStatus == "live" || appState.youtubeStatus == "testing" {
            return .failure("YouTube is still finishing the previous stream")
        }
        let streamID = Streamer.makeStreamID()
        Task {
            do {
                try await Streamer.shared.startStream(streamID: streamID)
            } catch {
                appState.activeAlert = error.localizedDescription
            }
        }
        return .success
    }

    private func handleStop(appState: AppState) async -> WatchCommandReply {
        Task {
            do {
                _ = try await Streamer.shared.endStream()
            } catch {
                appState.activeAlert = error.localizedDescription
            }
        }
        return .success
    }

    private func handleSaveHighlight(appState: AppState) async -> WatchCommandReply {
        guard let sessionID = appState.activitySession?.id else {
            return .failure("No active session")
        }
        do {
            try await HighlightRequestBridge.request(sessionID: sessionID)
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
