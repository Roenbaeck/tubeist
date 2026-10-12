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

struct WatchSessionManagerTests {
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
        let reply = await manager.handle(rawCommand: WatchCommand.saveHighlight.rawValue)
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
        let reply = await manager.handle(rawCommand: WatchCommand.saveHighlight.rawValue)
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
        let reply = await manager.handle(rawCommand: WatchCommand.saveHighlight.rawValue)
        #expect(reply.success == false)
        #expect(reply.message == HighlightIntentError.unavailable.errorDescription)
    }

    @Test func replyStructRoundTripsThroughPropertyListEncoding() throws {
        let data = try PropertyListEncoder().encode(WatchCommandReply.failure("nope"))
        let decoded = try PropertyListDecoder().decode(WatchCommandReply.self, from: data)
        #expect(decode(decoded) == (false, "nope"))
    }
}
