//
//  WatchConnectivityClient.swift
//  TubeistWatch Watch App
//
//  Watch-side counterpart to WatchSessionManager.swift on the iPhone.
//  Receives WatchStateSnapshot pushes and sends WatchCommand messages,
//  surfacing failures so the UI can show them rather than failing silently.
//

import Foundation
import WatchConnectivity

@MainActor
@Observable
final class WatchConnectivityClient: NSObject, WCSessionDelegate {
    static let shared = WatchConnectivityClient()

    private nonisolated static let payloadKey = "payload"
    /// WCSession.isReachable flips on its own (BLE/Wi-Fi radio renegotiation,
    /// the Watch's screen waking/sleeping) independent of whether the phone
    /// app is actually open, which made the Start button/"App not ready"
    /// flicker. The UI-facing value only drops to unreachable after staying
    /// that way for a bit; any "reachable" reading takes effect immediately.
    private static let unreachableDebounce: Duration = .seconds(3)

    private(set) var snapshot: WatchStateSnapshot = .idle
    private(set) var formattedExternalStatus = AttributedString()
    private(set) var isReachable = false
    private var started = false
    private var unreachableTask: Task<Void, Never>?
    /// Set on a failed command; the view clears it after showing an alert.
    var lastErrorMessage: String?

    func start() {
        guard !started else { return }
        started = true
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-watch-ui-fixture") {
            let now = Date()
            updateSnapshot(WatchStateSnapshot(generatedAt: now, phase: .streaming,
                startedAt: now.addingTimeInterval(-120), health: .good, healthTracked: true,
                healthValidUntil: now.addingTimeInterval(120), link: .good,
                canSaveHighlight: true, isAppActive: true,
                externalStatusConfigured: !ProcessInfo.processInfo.arguments.contains("-watch-ui-disabled"),
                externalStatus: try? ExternalStatusSnapshot(text:
                    ProcessInfo.processInfo.arguments.contains("-watch-ui-markdown")
                        ? "**Stage 2**\n*Next speaker*\n`12:30`\n[Details](https://example.com)"
                        : "**Lund – Hylte**\nSets: 1–2\n**Points: 23–21**",
                    receivedAt: now.addingTimeInterval(ProcessInfo.processInfo.arguments.contains("-watch-ui-stale") ? -60 : 0))))
            isReachable = true
            return
        }
#endif
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        receive(data: session.receivedApplicationContext[Self.payloadKey] as? Data)
        session.activate()
    }

    private func handleReachabilityChange(_ reachable: Bool) {
        unreachableTask?.cancel()
        if reachable {
            isReachable = true
        } else {
            unreachableTask = Task { [weak self] in
                try? await Task.sleep(for: Self.unreachableDebounce)
                guard !Task.isCancelled else { return }
                self?.isReachable = false
            }
        }
    }

    func sendStart() {
        send(.start)
    }

    func sendStop() {
        send(.stop)
    }

    func sendHighlight() {
        send(.saveHighlight)
    }

    private func send(_ command: WatchCommand) {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-watch-ui-fixture") { return }
#endif
        guard WCSession.default.isReachable else {
            lastErrorMessage = "iPhone not reachable"
            return
        }
        // WatchCommand has no associated data, so it travels as a plain
        // string under its own key — PropertyListEncoder refuses to encode
        // a bare top-level enum, since a plist's root must be a container.
        var message = [WatchCommand.key: command.rawValue]
        if let id = snapshot.sessionID { message[WatchCommand.sessionIDKey] = id.uuidString }
        WCSession.default.sendMessage(message, replyHandler: { [weak self] reply in
            let data = reply[Self.payloadKey] as? Data
            Task { @MainActor in
                self?.handle(replyData: data)
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.lastErrorMessage = error.localizedDescription
            }
        })
    }

    private func handle(replyData: Data?) {
        guard let data = replyData,
              let decoded = try? PropertyListDecoder().decode(WatchCommandReply.self, from: data) else {
            lastErrorMessage = "Unexpected reply from iPhone"
            return
        }
        if !decoded.success {
            lastErrorMessage = decoded.message ?? "The action failed"
        }
    }

    // MARK: - WCSessionDelegate
    // Apple calls these on a background thread; none are MainActor-isolated.

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            LOG("Watch session activation failed: \(error.localizedDescription)")
        }
        let reachable = session.isReachable
        let data = session.receivedApplicationContext[Self.payloadKey] as? Data
        Task { @MainActor in
            self.receive(data: data)
            self.handleReachabilityChange(reachable)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.handleReachabilityChange(reachable)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext[Self.payloadKey] as? Data
        Task { @MainActor in self.receive(data: data) }
    }

    private func receive(data: Data?) {
        guard let data,
              let decoded = try? PropertyListDecoder().decode(WatchStateSnapshot.self, from: data),
              decoded.generatedAt >= snapshot.generatedAt else { return }
        updateSnapshot(decoded)
    }

    private func updateSnapshot(_ updated: WatchStateSnapshot) {
        // Heartbeats and the view's one-second clock must not reparse Markdown.
        if updated.externalStatus?.text != snapshot.externalStatus?.text {
            formattedExternalStatus = updated.externalStatus.map { WatchStatusMarkdown.render($0.text) }
                ?? AttributedString()
        }
        snapshot = updated
    }
}

/// watchOS has no shared LOG() helper from the iPhone target; a minimal
/// stand-in keeps WatchConnectivityClient's logging calls self-contained.
private nonisolated func LOG(_ message: String) {
    print("[TubeistWatch] \(message)")
}
