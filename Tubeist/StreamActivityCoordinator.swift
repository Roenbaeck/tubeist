//
//  StreamActivityCoordinator.swift
//  Tubeist
//
//  Runs while a stream is live: every 5 s builds a StreamSnapshot from AppState,
//  device metrics and the latest YouTube polls, asks StreamActivityPolicy what
//  to do, and hands the decision to StreamActivityController. Runs entirely off
//  the media pipeline; failures keep the last known values (which then go stale).
//

import Foundation
import UIKit

@MainActor
final class StreamActivityCoordinator {
    private static let tick: Duration = .seconds(5)
    // Polling costs YouTube API quota: one unit per call against a default 10,000
    // per day. At 30 s, health is 120 units/h; viewers at 60 s another 60 units/h,
    // so a long Full-detail stream stays well inside the daily budget.
    private static let healthInterval: TimeInterval = 30
    private static let viewerInterval: TimeInterval = 60
    private static let quotaBackoff: TimeInterval = 300

    /// How long a highlight status overlay (e.g. "Saving highlight…") stays
    /// visible before the coordinator forces a push that clears it again.
    private static let highlightStatusDisplayDuration: TimeInterval = 10

    private struct PendingHighlightEvent {
        var status: HighlightStatus
        var alert: StreamAlert?
    }

    private let controller: any StreamActivitySink
    private var task: Task<Void, Never>?
    /// The pending teardown of the previous loop. A new loop waits for it, so a
    /// stop() that is immediately followed by a start() can never end the activity
    /// the new loop has just requested.
    private var teardown: Task<Void, Never>?
    /// A one-off highlight event (status overlay, optionally with a loud alert)
    /// waiting for the next tick, set via notify(status:alert:). Delivered
    /// outside the throttled health-alert state machine in StreamActivityPolicy.
    private var pendingHighlightEvent: PendingHighlightEvent?
    /// When the current highlightStatus overlay should be cleared again.
    private var highlightStatusExpiry: Date?

    init(controller: any StreamActivitySink = StreamActivityController()) {
        self.controller = controller
    }

    /// Queues a highlight status overlay (and, for terminal outcomes, a loud
    /// alert) for delivery on the loop's next tick (at most Self.tick later).
    /// The overlay auto-clears itself after highlightStatusDisplayDuration. A
    /// no-op if the loop isn't running (e.g. nothing is live).
    func notify(status: HighlightStatus, alert: StreamAlert? = nil) {
        pendingHighlightEvent = PendingHighlightEvent(status: status, alert: alert)
        highlightStatusExpiry = Date().addingTimeInterval(Self.highlightStatusDisplayDuration)
    }

    func start(appState: AppState, youtubeService: YouTubeService) {
        // Cancel and fully tear down whatever was running first; the new loop then
        // waits for that teardown before touching the Live Activity.
        stop()
        let detail = Settings.liveActivityDetail
        let alertOnBad = Settings.alertOnBadHealth
        guard detail != .off || alertOnBad else { return }

        let pendingTeardown = teardown
        task = Task { [weak self, controller] in
            await pendingTeardown?.value
            guard !Task.isCancelled else { return }
            // Only installs the delegate. Authorization is requested away from
            // go-live (TubeistView.onAppear), so no system modal lands on the
            // camera UI as the stream starts.
            if alertOnBad || Settings.alertOnRecovery { StreamAlertNotifier.prepare() }
            UIDevice.current.isBatteryMonitoringEnabled = true

            var policy = StreamActivityPolicy(
                detail: detail,
                alertOnBad: alertOnBad,
                alertOnRecovery: Settings.alertOnRecovery
            )
            // Only used if the session start is somehow unknown; the Live Activity's
            // elapsed timer otherwise runs from when the stream actually went live.
            let fallbackStartedAt = Date()
            var health = YouTubeStreamHealth.unknown
            var healthUpdatedAt: Date?
            var viewers: Int?
            var nextHealthPoll = Date.distantPast
            var nextViewerPoll = Date.distantPast

            while !Task.isCancelled {
                let now = Date()

                if now >= nextHealthPoll, let streamId = appState.youtubeStreamId {
                    do {
                        health = try await youtubeService.fetchStreamHealth(streamId: streamId)
                        healthUpdatedAt = now
                        nextHealthPoll = now.addingTimeInterval(Self.healthInterval)
                    } catch {
                        LOG("Stream health poll failed: \(error.localizedDescription)", level: .debug)
                        nextHealthPoll = now.addingTimeInterval(Self.backoff(after: error))
                    }
                }
                if detail == .full, now >= nextViewerPoll, let videoId = appState.youtubeBroadcastId {
                    do {
                        viewers = try await youtubeService.fetchConcurrentViewers(videoId: videoId)
                        nextViewerPoll = now.addingTimeInterval(Self.viewerInterval)
                    } catch {
                        LOG("Viewer poll failed: \(error.localizedDescription)", level: .debug)
                        nextViewerPoll = now.addingTimeInterval(Self.backoff(after: error))
                    }
                }

                // Standard detail discards the bitrate, so only Full pays for the read.
                // This is the non-mutating read: asking for a *recommendation* would run
                // the adaptive-bitrate controller and steal the encoding pipeline's own
                // evaluation slot.
                let bitrate = detail == .full
                    ? await EncodedOutputRouter.shared.currentVideoBitrate()
                    : nil
                // A poll cancelled mid-flight surfaces as a thrown error and lands
                // here, so re-check before touching the Live Activity: a stopped loop
                // must never start or update one behind stop()'s back.
                guard !Task.isCancelled else { break }
                let snapshot = Self.snapshot(
                    appState: appState,
                    health: health,
                    healthUpdatedAt: healthUpdatedAt,
                    viewers: viewers,
                    bitrateKbps: bitrate.map { $0 / 1000 }
                )
                // A fresh event takes priority; otherwise, if the currently shown
                // overlay has expired, force one more push that clears it back to
                // nil rather than leaving it stuck until the next natural update.
                var shouldUpdateHighlightStatus = false
                var newHighlightStatus: HighlightStatus?
                var forcedAlert: StreamAlert?
                if let event = self?.pendingHighlightEvent {
                    self?.pendingHighlightEvent = nil
                    shouldUpdateHighlightStatus = true
                    newHighlightStatus = event.status
                    forcedAlert = event.alert
                } else if let expiry = self?.highlightStatusExpiry, now >= expiry {
                    self?.highlightStatusExpiry = nil
                    shouldUpdateHighlightStatus = true
                }
                var decision = policy.evaluate(snapshot, now: now, forceContent: shouldUpdateHighlightStatus)
                if shouldUpdateHighlightStatus {
                    decision.content?.highlightStatus = newHighlightStatus
                }
                if let forcedAlert { decision.alert = forcedAlert }
                await controller.apply(
                    decision,
                    streamStartedAt: appState.streamStartedAt ?? fallbackStartedAt,
                    now: now
                )

                try? await Task.sleep(for: Self.tick)
            }
        }
    }

    func stop() {
        // Nothing running means the previous stop already scheduled the teardown.
        guard let running = task else { return }
        task = nil
        running.cancel()
        let pendingTeardown = teardown
        teardown = Task { [controller] in
            await pendingTeardown?.value
            // Ending only once the loop is out guarantees no update can follow the
            // end and resurrect an activity nothing would ever end again.
            await running.value
            await controller.end()
        }
    }

    /// Quota rejections are expensive to retry, so they wait out a long backoff;
    /// everything else retries at the normal health cadence.
    static func backoff(after error: Error) -> TimeInterval {
        if case YouTubeError.apiError(403, _) = error { return quotaBackoff }
        return healthInterval
    }

    /// UIKit reports a negative level when battery monitoring is unavailable.
    static func batteryPercent(from level: Float) -> Int? {
        level < 0 ? nil : Int(level * 100)
    }

    static func snapshot(
        appState: AppState,
        health: YouTubeStreamHealth,
        healthUpdatedAt: Date?,
        viewers: Int?,
        bitrateKbps: Int?
    ) -> StreamSnapshot {
        let phase: StreamPhase = switch appState.streamSessionState {
        case .preparing: .connecting
        case .live: .live
        case .stopping: .stopping
        case .idle, .failed: appState.isAwaitingYouTubeCompletion ? .finalizing : .ended
        }
        let (link, warning): (LinkQuality, String?) = switch appState.streamHealth {
        case .pristine: (.good, nil)
        case .degraded: (.degraded, "Upload degraded")
        case .unusable: (.poor, "Upload problem")
        case .awaiting, .silenced: (.unknown, nil)
        }
        let thermal: ThermalLevel = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
        return StreamSnapshot(
            phase: phase,
            youtubeHealth: health,
            // Without a bound YouTube stream id (manual stream key, or not signed in)
            // nothing polls health, so the Live Activity must not pretend to show it.
            healthTracked: appState.youtubeStreamId != nil,
            healthUpdatedAt: healthUpdatedAt,
            viewers: viewers,
            bitrateKbps: bitrateKbps,
            link: link,
            thermal: thermal,
            batteryPercent: batteryPercent(from: UIDevice.current.batteryLevel),
            warning: warning,
            youtubeStatusLabel: phase == .finalizing ? appState.youtubeStatus : nil
        )
    }
}
