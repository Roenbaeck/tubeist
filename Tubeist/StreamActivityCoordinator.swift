import Foundation
import UIKit

@MainActor
final class StreamActivityCoordinator {
    typealias Read = @MainActor () -> StreamActivitySnapshot?
    typealias Viewers = @MainActor (YouTubeHealthTarget) async throws -> Int?
    private let sink: any StreamActivitySink
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    private var runner: Task<Void, Never>?
    private var viewerTask: Task<Void, Never>?
    private var viewerGeneration = UUID()
    private var viewers: Int?
    private var viewersAt: Date?
    private var nextViewerPoll = Date.distantPast
    private var viewerFailures = 0
    private var policy = StreamActivityPolicy()
    private var policySessionID: UUID?

    init(sink: any StreamActivitySink = StreamActivityController(), now: @escaping () -> Date = Date.init,
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sink = sink
        self.now = now
        self.sleep = sleep
    }

    /// SwiftUI owns cancellation, but each replacement waits for the previous loop
    /// and ActivityKit call to finish. An old teardown cannot end a newer activity.
    func run(preferences: StreamActivityPreferences, read: @escaping Read, fetchViewers: @escaping Viewers,
             bitrate: @escaping @MainActor () async -> Int?) async {
        let previous = runner
        previous?.cancel()
        let running = Task { [self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            let sessionID = read()?.session.id
            if policySessionID != sessionID {
                policy = StreamActivityPolicy()
                policySessionID = sessionID
            } else {
                policy.resetPresentation()
            }
            await sink.begin(sessionID: sessionID)
            guard !Task.isCancelled, let sessionID else { return }
            guard preferences.detail != .off else {
                policy = StreamActivityPolicy()
                return
            }
            while !Task.isCancelled, var snapshot = read(), snapshot.session.id == sessionID {
                let instant = now()
                let terminal = snapshot.content.phase.isTerminal
                if preferences.detail == .full, snapshot.content.phase == .streaming {
                    if let target = snapshot.viewersTarget {
                        pollViewersIfNeeded(target: target, fetch: fetchViewers, now: instant)
                    } else {
                        cancelViewers()
                    }
                    snapshot.content.viewers = Self.freshViewers(viewers, receivedAt: viewersAt, now: instant)
                    let measuredBitrate = await bitrate()
                    // Session state may have changed while reading the metrics actor.
                    guard !Task.isCancelled else { break }
                    guard let current = read(), current.session.id == sessionID else { break }
                    guard current.content.phase == snapshot.content.phase else { continue }
                    snapshot.content.bitrateKbps = measuredBitrate.map { $0 / 1000 }
                } else {
                    cancelViewers()
                }
                let decision = policy.evaluate(snapshot, preferences: preferences, now: instant)
                if let content = decision.content {
                    await sink.publish(content, alert: decision.alert, now: instant)
                }
                if terminal {
                    cancelViewers()
                    await sink.finish(snapshot.content, now: now())
                    return
                }
                do { try await sleep(.seconds(5)) } catch { break }
            }
            cancelViewers()
            await sink.finish(nil, now: now())
        }
        runner = running
        await withTaskCancellationHandler { await running.value } onCancel: { running.cancel() }
    }

    private func pollViewersIfNeeded(target: YouTubeHealthTarget, fetch: @escaping Viewers, now: Date) {
        guard viewerTask == nil, now >= nextViewerPoll else { return }
        let generation = viewerGeneration
        nextViewerPoll = now.addingTimeInterval(60)
        viewerTask = Task { [weak self] in
            do {
                let count = try await fetch(target)
                guard let self, !Task.isCancelled, generation == viewerGeneration else { return }
                viewers = count
                viewersAt = self.now()
                viewerFailures = 0
                nextViewerPoll = self.now().addingTimeInterval(60)
                viewerTask = nil
            } catch {
                guard let self, !Task.isCancelled, generation == viewerGeneration else { return }
                viewerFailures += 1
                nextViewerPoll = self.now().addingTimeInterval(min(300, 60 * pow(2, Double(min(viewerFailures, 3)))))
                LOG("YouTube viewer count unavailable; streaming continues", level: .debug)
                viewerTask = nil
            }
        }
    }

    private func cancelViewers() {
        viewerTask?.cancel()
        viewerTask = nil
        viewerGeneration = UUID()
        viewers = nil
        viewersAt = nil
        nextViewerPoll = .distantPast
        viewerFailures = 0
    }

    static func freshViewers(_ count: Int?, receivedAt: Date?, now: Date) -> Int? {
        guard let receivedAt, now.timeIntervalSince(receivedAt) <= 120 else { return nil }
        return count
    }
}

extension AppState {
    func activitySnapshot(preferences: StreamActivityPreferences, now: Date = Date()) -> StreamActivitySnapshot? {
        guard let session = activitySession else { return nil }
        let phase: StreamActivityPhase = switch streamSessionState {
        case .preparing: .preparing
        case .live: session.streamsToYouTube ? .streaming : .recording
        case .stopping: .finishing
        case .idle: .ended
        case .failed: .failed
        }
        let local: StreamActivityLink = switch localUploadHealth {
        case .pristine: .good
        case .degraded: .degraded
        case .unusable: .failed
        case .awaiting, .silenced: .unknown
        }
        let health: StreamActivityHealth = switch youtubeHealth.assessment.kind {
        case .waiting: .waiting
        case .unknown: .unknown
        case .good: .good
        case .warning: .warning
        case .error: .error
        }
        let thermal: StreamActivityThermal = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .normal
        case .fair: .warm
        case .serious: .hot
        case .critical: .critical
        @unknown default: .normal
        }
        let full = preferences.detail == .full
        let battery = UIDevice.current.batteryLevel
        var content = StreamActivityAttributes.ContentState(phase: phase, startedAt: session.startedAt,
            stoppedAt: session.stoppedAt, health: health, healthTracked: youtubeHealth.target != nil,
            link: local, viewers: nil, bitrateKbps: nil,
            batteryPercent: full && battery >= 0 ? Int((battery * 100).rounded()) : nil,
            thermal: full ? thermal : nil, fullDetail: full)
        if youtubeHealth.target != nil, let receivedAt = youtubeHealth.receivedAt {
            let sourceDate = youtubeHealth.report?.healthStatus?.lastUpdateTimeSeconds.map(Date.init(timeIntervalSince1970:))
            content.healthValidUntil = min(receivedAt.addingTimeInterval(120),
                sourceDate?.addingTimeInterval(120) ?? .distantFuture)
        }
        let isFresh = youtubeHealth.lastRefreshSucceeded && youtubeHealth.receivedAt.map {
            now.timeIntervalSince($0) <= 120
        } == true
        // noData alone isn't proof of failed delivery. Inactivity only becomes an
        // alert candidate after startup, and still needs two fresh observations.
        let inactive = youtubeHealth.report?.streamStatus == "inactive"
            && now.timeIntervalSince(session.startedAt ?? session.requestedAt) >= 60
        return .init(session: session, content: content, healthReceivedAt: youtubeHealth.receivedAt,
            remoteProblem: isFresh && (health == .error || inactive),
            remoteHealthy: isFresh && health == .good, viewersTarget: soonGoingToBackground ? nil : youtubeHealth.target)
    }
}
