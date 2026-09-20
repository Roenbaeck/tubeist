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
    private static let healthInterval: TimeInterval = 15
    private static let viewerInterval: TimeInterval = 30
    private static let quotaBackoff: TimeInterval = 300

    private let controller = StreamActivityController()
    private var task: Task<Void, Never>?

    func start(appState: AppState, youtubeService: YouTubeService) {
        task?.cancel()
        let detail = Settings.liveActivityDetail
        let alertOnBad = Settings.alertOnBadHealth
        guard detail != .off || alertOnBad else { return }

        task = Task { [controller] in
            if alertOnBad || Settings.alertOnRecovery { await StreamAlertNotifier.prepare() }
            UIDevice.current.isBatteryMonitoringEnabled = true

            var policy = StreamActivityPolicy(
                detail: detail,
                alertOnBad: alertOnBad,
                alertOnRecovery: Settings.alertOnRecovery
            )
            let startedAt = Date()
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

                let bitrate = await EncodedOutputRouter.shared.recommendedVideoBitrate()
                let snapshot = Self.snapshot(
                    appState: appState,
                    health: health,
                    healthUpdatedAt: healthUpdatedAt,
                    viewers: viewers,
                    bitrateKbps: bitrate.map { $0 / 1000 }
                )
                let decision = policy.evaluate(snapshot, now: now)
                await controller.apply(decision, streamStartedAt: startedAt, now: now)

                try? await Task.sleep(for: Self.tick)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        Task { [controller] in await controller.end() }
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
        case .idle, .failed: .ended
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
            healthUpdatedAt: healthUpdatedAt,
            viewers: viewers,
            bitrateKbps: bitrateKbps,
            link: link,
            thermal: thermal,
            batteryPercent: batteryPercent(from: UIDevice.current.batteryLevel),
            warning: warning
        )
    }
}
