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

@MainActor
final class WatchSessionManager: NSObject, WCSessionDelegate {
    static let shared = WatchSessionManager()

    private nonisolated static let payloadKey = "payload"
    private static let pushInterval: Duration = .seconds(2)

    var appState: AppState?
    private var pushTask: Task<Void, Never>?
    private var lastPushedSnapshot: WatchStateSnapshot?
    private let relay = ExternalStatusRelay()
    private let isAppActive: @MainActor () -> Bool
    private var lifecycleObservers: [NSObjectProtocol] = []

    init(isAppActive: @escaping @MainActor () -> Bool = {
        UIApplication.shared.applicationState == .active
    }) {
        self.isAppActive = isAppActive
        super.init()
    }

    func start(appState: AppState) {
        self.appState = appState
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        startPushLoop()
        observeAppLifecycle()
    }

    /// Pushes immediately on a foreground/background transition rather than
    /// waiting for the next pushLoop tick, since the Watch's Start button
    /// gates on isAppActive and backgrounding can happen right before the
    /// app gets suspended (and the loop with it).
    private func observeAppLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name: Notification.Name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.pushStateIfNeeded()
                }
            }
            lifecycleObservers.append(observer)
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

    private func pushStateIfNeeded() {
        guard let appState else { return }
        let session = WCSession.default
        let endpoint = ExternalStatusClient.endpoint(Settings.externalStatusURL)
        let context: ExternalStatusRelay.Context?
        if session.isPaired, session.isWatchAppInstalled,
           isAppActive(), !appState.soonGoingToBackground, appState.isStreamActive,
           let id = appState.activitySession?.id, let endpoint {
            context = .init(url: endpoint, sessionID: id)
        } else {
            context = nil
        }
        relay.update(context: context)
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let snapshot = currentSnapshot(appState: appState)
        // A heartbeat lets the Watch expire state even if the phone stops
        // delivering updates while all other fields remain unchanged.
        if let last = lastPushedSnapshot, snapshot.hasSameContent(as: last),
           snapshot.generatedAt.timeIntervalSince(last.generatedAt) < 15 { return }
        do {
            let data = try PropertyListEncoder().encode(snapshot)
            try session.updateApplicationContext([Self.payloadKey: data])
            lastPushedSnapshot = snapshot
        } catch {
            LOG("Could not push Watch state: \(error.localizedDescription)", level: .debug)
        }
    }

    func currentSnapshot(appState: AppState) -> WatchStateSnapshot {
        var snapshot = WatchStateSnapshot.idle
        snapshot.generatedAt = Date()
        snapshot.isAppActive = isAppActive() && !appState.soonGoingToBackground && !appState.isAppInitialization
        snapshot.externalStatusConfigured = ExternalStatusClient.endpoint(Settings.externalStatusURL) != nil
        if let activity = appState.activitySnapshot(preferences: appState.activityPreferences) {
            let content = activity.content
            snapshot.sessionID = appState.activitySession?.id
            snapshot.phase = content.phase
            snapshot.startedAt = content.startedAt
            snapshot.stoppedAt = content.stoppedAt
            snapshot.health = content.health
            snapshot.healthTracked = content.healthTracked
            snapshot.healthValidUntil = content.healthValidUntil
            snapshot.link = content.link
            snapshot.batteryPercent = content.batteryPercent
            snapshot.canSaveHighlight = content.canSaveHighlight
            snapshot.highlightStatus = content.highlightStatus
        }
        snapshot.externalStatus = relay.latest
        snapshot.externalStatusRefreshFailed = relay.refreshFailed
        return snapshot
    }

    private func refreshConnection() {
        lastPushedSnapshot = nil
        pushStateIfNeeded()
    }

    // MARK: - WCSessionDelegate
    // Apple calls these on a background thread, so none of them are
    // MainActor-isolated; each hops over explicitly where needed.

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in self.refreshConnection() }
        if let error {
            LOG("Watch session activation failed: \(error.localizedDescription)", level: .warning)
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshConnection() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshConnection() }
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
        let sessionID = (message[WatchCommand.sessionIDKey] as? String).flatMap(UUID.init(uuidString:))
        let boxedReply = SendableReplyHandler(handler: replyHandler)
        Task { @MainActor in
            let reply = await self.handle(rawCommand: rawCommand, sessionID: sessionID)
            let data = (try? PropertyListEncoder().encode(reply)) ?? Data()
            boxedReply.handler([Self.payloadKey: data])
        }
    }

    func handle(rawCommand: String?, sessionID: UUID? = nil) async -> WatchCommandReply {
        guard let rawCommand, let command = WatchCommand(rawValue: rawCommand) else {
            return .failure("Unrecognized command")
        }
        guard let appState else { return .failure("Tubeist is not ready") }
        if command != .start {
            guard let currentID = appState.activitySession?.id else { return .failure("No active session") }
            guard sessionID == currentID else { return .failure("Session changed; wait for the Watch to update") }
        }
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
    /// push (phase) instead of the message reply.
    private func handleStart(appState: AppState) async -> WatchCommandReply {
        if appState.youtubeStatus == "live" || appState.youtubeStatus == "testing" {
            return .failure("YouTube is still finishing the previous stream")
        }
        guard isAppActive(), !appState.soonGoingToBackground, !appState.isAppInitialization else {
            return .failure("Open Tubeist on your iPhone before starting")
        }
        let streamID = Streamer.makeStreamID()
        Task {
            guard isAppActive(), !appState.soonGoingToBackground else { return }
            do {
                try await Streamer.shared.startStream(streamID: streamID)
            } catch {
                appState.activeAlert = error.localizedDescription
            }
        }
        return .success
    }

    private func handleStop(appState: AppState) async -> WatchCommandReply {
        let sessionID = appState.activitySession?.id
        Task {
            guard appState.activitySession?.id == sessionID else { return }
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
