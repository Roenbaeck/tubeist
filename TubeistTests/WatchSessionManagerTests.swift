// Covers the parts of WatchSessionManager's command handling that don't
// require a real camera/network session: decode failures and the guards
// that return before ever touching Streamer.shared, plus highlight
// bridging (which goes through the fakeable HighlightRequestBridge.handler
// closure, the same seam SaveHighlightIntent already uses).
import Foundation
import Testing
@testable import Tubeist

private func decode(_ reply: WatchCommandReply) -> (success: Bool, message: String?) {
    (reply.success, reply.message)
}

@Suite(.serialized)
struct WatchSessionManagerTests {
    @Test @MainActor
    func settingsDisablesWatchStartUntilDismissal() async {
        let manager = WatchSessionManager(isAppActive: { true })
        let app = AppState()
        app.isAppInitialization = false
        app.isSettingsPresented = true
        manager.appState = app
        #expect(!manager.currentSnapshot(appState: app).isAppActive)
        let reply = await manager.handle(rawCommand: WatchCommand.start.rawValue)
        #expect(decode(reply) == (false, "Close Settings on your iPhone before starting"))
        #expect(app.streamSessionState == .idle)
        app.isSettingsPresented = false
        #expect(manager.currentSnapshot(appState: app).isAppActive)
    }

    @Test @MainActor
    func keyConflictFromWatchStartAsksForThePhone() async {
        let conflict = YouTubeKeyConflict(
            kind: .plannedNeedsOwnKey, broadcastTitle: "Match 5", otherTitle: "Match 6", broadcastIDsToMove: ["b5"]
        )
        let manager = WatchSessionManager(isAppActive: { true }, startStream: { _ in
            throw YouTubeError.keyConflict(conflict)
        })
        let app = AppState()
        app.isAppInitialization = false
        manager.appState = app
        let reply = await manager.handle(rawCommand: WatchCommand.start.rawValue)
        #expect(reply.success)
        for _ in 0..<200 where app.activeAlert == nil { await Task.yield() }
        #expect(app.activeAlert == "Open Tubeist on the phone to set up 'Match 5'.")
    }

    @Test @MainActor
    func otherWatchStartErrorsKeepTheirOwnMessage() async {
        let manager = WatchSessionManager(isAppActive: { true }, startStream: { _ in
            throw YouTubeError.keyBlocked("Match 5")
        })
        let app = AppState()
        app.isAppInitialization = false
        manager.appState = app
        _ = await manager.handle(rawCommand: WatchCommand.start.rawValue)
        for _ in 0..<200 where app.activeAlert == nil { await Task.yield() }
        #expect(app.activeAlert == YouTubeError.keyBlocked("Match 5").localizedDescription)
    }

    @Test @MainActor
    func startIsRejectedWhenPhoneIsInactive() async {
        let manager = WatchSessionManager(isAppActive: { false })
        let appState = AppState()
        appState.isAppInitialization = false
        manager.appState = appState
        let reply = await manager.handle(rawCommand: WatchCommand.start.rawValue)
        #expect(reply.success == false)
        #expect(reply.message == "Open Tubeist on your iPhone before starting")
    }

    @Test @MainActor
    func unrecognizedCommandIsRejected() async throws {
        let manager = WatchSessionManager()
        manager.appState = AppState()
        let reply = await manager.handle(rawCommand: "not-a-real-command")
        #expect(decode(reply) == (false, "Unrecognized command"))
    }

    @Test @MainActor
    func missingCommandIsRejected() async throws {
        let manager = WatchSessionManager()
        manager.appState = AppState()
        let reply = await manager.handle(rawCommand: nil)
        #expect(decode(reply) == (false, "Unrecognized command"))
    }

    @Test @MainActor
    func commandsAreRejectedBeforeAppStateIsInstalled() async throws {
        let manager = WatchSessionManager()
        let reply = await manager.handle(rawCommand: WatchCommand.start.rawValue)
        #expect(decode(reply) == (false, "Tubeist is not ready"))
    }

    @Test @MainActor
    func startIsRejectedWhileAPreviousBroadcastIsStillFinishing() async throws {
        let manager = WatchSessionManager()
        let appState = AppState()
        appState.youtubeStatus = "live"
        manager.appState = appState
        let reply = await manager.handle(rawCommand: WatchCommand.start.rawValue)
        #expect(decode(reply) == (false, "YouTube is still finishing the previous stream"))
    }

    @Test @MainActor
    func startIsRejectedWhileATestBroadcastIsStillFinishing() async throws {
        let manager = WatchSessionManager()
        let appState = AppState()
        appState.youtubeStatus = "testing"
        manager.appState = appState
        let reply = await manager.handle(rawCommand: WatchCommand.start.rawValue)
        #expect(decode(reply) == (false, "YouTube is still finishing the previous stream"))
    }

    @Test @MainActor
    func highlightIsRejectedWithoutAnActiveSession() async throws {
        let manager = WatchSessionManager()
        let appState = AppState()
        appState.activitySession = nil
        manager.appState = appState
        let reply = await manager.handle(rawCommand: WatchCommand.saveHighlight.rawValue, sessionID: appState.activitySession?.id)
        #expect(decode(reply) == (false, "No active session"))
    }

    @Test @MainActor
    func highlightBridgesToTheSameHandlerTheLiveActivityUses() async throws {
        let manager = WatchSessionManager()
        let appState = AppState()
        let sessionID = UUID()
        appState.activitySession = StreamActivitySession(
            id: sessionID, requestedAt: Date(), streamsToYouTube: true
        )
        manager.appState = appState
        defer { HighlightRequestBridge.handler = nil }

        var requestedSessionID: UUID?
        HighlightRequestBridge.handler = { id in requestedSessionID = id }
        let reply = await manager.handle(rawCommand: WatchCommand.saveHighlight.rawValue, sessionID: appState.activitySession?.id)
        #expect(decode(reply) == (true, nil))
        #expect(requestedSessionID == sessionID)
    }

    @Test @MainActor
    func highlightFailureIsSurfacedRatherThanSwallowed() async throws {
        let manager = WatchSessionManager()
        let appState = AppState()
        appState.activitySession = StreamActivitySession(
            id: UUID(), requestedAt: Date(), streamsToYouTube: true
        )
        manager.appState = appState
        defer { HighlightRequestBridge.handler = nil }

        HighlightRequestBridge.handler = { _ in throw HighlightIntentError.unavailable }
        let reply = await manager.handle(rawCommand: WatchCommand.saveHighlight.rawValue, sessionID: appState.activitySession?.id)
        #expect(reply.success == false)
        #expect(reply.message == HighlightIntentError.unavailable.errorDescription)
    }

    @Test @MainActor
    func oldSessionCommandsCannotAffectANewSession() async {
        let manager = WatchSessionManager()
        let appState = AppState()
        appState.activitySession = StreamActivitySession(id: UUID(), requestedAt: Date(), streamsToYouTube: true)
        manager.appState = appState
        for command in [WatchCommand.stop, .saveHighlight] {
            let reply = await manager.handle(rawCommand: command.rawValue, sessionID: UUID())
            #expect(reply.success == false)
            #expect(reply.message == "Session changed; wait for the Watch to update")
        }
    }

    @Test func replyStructRoundTripsThroughPropertyListEncoding() throws {
        let data = try PropertyListEncoder().encode(WatchCommandReply.failure("nope"))
        let decoded = try PropertyListDecoder().decode(WatchCommandReply.self, from: data)
        #expect(decode(decoded) == (false, "nope"))
    }
}
