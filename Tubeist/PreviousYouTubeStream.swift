//
//  PreviousYouTubeStream.swift
//  Tubeist
//

import Foundation

/// Start refuses while YouTube reports the broadcast on this phone's key as
/// live or testing. That status is cached: while idle, Tubeist refreshes it at
/// launch and briefly after Stop, and YouTube can end the broadcast later.
/// Start therefore rechecks it before refusing. Start's own YouTube preflight
/// still refuses an active broadcast, so a recheck that cannot reach YouTube
/// lets Start continue rather than block it on a stale value.
@MainActor
enum PreviousYouTubeStream {
    /// Short enough for a Watch command to get its reply.
    static let recheckTimeout: Duration = .seconds(3)

    static func blocksStart(_ status: String?) -> Bool {
        status == "live" || status == "testing"
    }

    /// Whether Start must still be refused. Updates the cached status when
    /// YouTube answers and nothing else has changed it in the meantime.
    static func isStillActive(
        appState: AppState,
        timeout: Duration = recheckTimeout,
        fetchStatus: @escaping @MainActor (String) async throws -> String?
    ) async -> Bool {
        guard blocksStart(appState.youtubeStatus) else { return false }
        // Without the broadcast the status describes, there is nothing to recheck.
        guard let broadcastID = appState.youtubeBroadcastId else { return true }
        let sessionState = appState.streamSessionState
        guard case .status(let status) = await fetch(broadcastID, timeout: timeout, fetchStatus: fetchStatus) else {
            LOG("Could not recheck the previous YouTube broadcast; Start's preflight will check it", level: .debug)
            return false
        }
        guard appState.youtubeBroadcastId == broadcastID, appState.streamSessionState == sessionState else {
            return blocksStart(appState.youtubeStatus)
        }
        appState.youtubeStatus = status
        if !blocksStart(status) {
            LOG("The previous YouTube broadcast is no longer live (\(status ?? "not found")); Start can continue", level: .info)
        }
        return blocksStart(status)
    }

    private enum Outcome: Sendable {
        case status(String?)
        case unavailable
    }

    /// Bounded even if the request ignores cancellation, for example while an
    /// access-token refresh it joined is still in flight.
    private static func fetch(
        _ broadcastID: String, timeout: Duration,
        fetchStatus: @escaping @MainActor (String) async throws -> String?
    ) async -> Outcome {
        await withCheckedContinuation { continuation in
            let reply = SingleReply(continuation)
            let request = Task { @MainActor in
                let outcome: Outcome
                do { outcome = .status(try await fetchStatus(broadcastID)) } catch { outcome = .unavailable }
                reply.resume(outcome)
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                request.cancel()
                reply.resume(.unavailable)
            }
        }
    }
}

@MainActor
private final class SingleReply<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
