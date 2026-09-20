//
//  Streamer.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-06.
//
import CoreMedia
import UIKit

enum StreamHealth: Equatable {
    case silenced   // When stream is not running
    case awaiting   // Health has not been determined
    case unusable   // Stream is too bad to watch
    case degraded   // Noticeable quality issues
    case pristine   // Perfect viewing experience

    var statusDescription: String {
        switch self {
        case .silenced: "Not streaming"
        case .awaiting: "Waiting for stream health"
        case .unusable: "Stream failure"
        case .degraded: "Stream degraded"
        case .pristine: "Stream healthy"
        }
    }
}

enum StreamSessionState: Equatable, Sendable {
    case idle
    case preparing
    case live
    case stopping
    case failed(String)

    var isLive: Bool {
        if case .live = self { true } else { false }
    }

    var isTransitioning: Bool {
        switch self {
        case .preparing, .stopping: true
        case .idle, .live, .failed: false
        }
    }

    var ownsMediaPipeline: Bool {
        switch self {
        case .preparing, .live, .stopping: true
        case .idle, .failed: false
        }
    }
}

enum StreamSessionError: LocalizedError, Equatable {
    case sessionBusy(StreamSessionState)
    case invalidTransition(from: StreamSessionState, to: StreamSessionState)

    var errorDescription: String? {
        switch self {
        case .sessionBusy(let state):
            "The streaming session is already \(state.statusDescription)"
        case .invalidTransition(let from, let to):
            "The streaming session cannot change from \(from.statusDescription) to \(to.statusDescription)"
        }
    }
}

extension StreamSessionState {
    var statusDescription: String {
        switch self {
        case .idle: "idle"
        case .preparing: "preparing"
        case .live: "live"
        case .stopping: "stopping"
        case .failed: "failed"
        }
    }
}

struct StreamOutputPlan: Sendable, Equatable {
    let streamsToYouTube: Bool
    let recordsLocally: Bool

    var routesEncodedFragments: Bool { streamsToYouTube }
    var remuxesToTransportStream: Bool { streamsToYouTube }

    static func resolve(
        stream: Bool,
        record: Bool
    ) throws -> StreamOutputPlan {
        guard stream || record else {
            throw StreamStartError.noOutputSelected
        }
        guard stream else {
            return StreamOutputPlan(streamsToYouTube: false, recordsLocally: record)
        }
        return StreamOutputPlan(streamsToYouTube: true, recordsLocally: record)
    }
}

enum CaptureTailAlignment {
    static let maximumVideoCatchUpSeconds = 5.0

    static func videoHasReached(
        stopTimestamp: CMTime,
        videoTimestamp: CMTime?
    ) -> Bool {
        guard let videoTimestamp else { return false }
        let stopSeconds = CMTimeGetSeconds(stopTimestamp)
        let videoSeconds = CMTimeGetSeconds(videoTimestamp)
        guard stopSeconds.isFinite, videoSeconds.isFinite else { return false }
        return CMTimeCompare(videoTimestamp, stopTimestamp) >= 0
    }
}

enum YouTubeCompletionGrace {
    // Shutdown experiment: observe YouTube's natural end before intervening.
    static let duration: Duration = .seconds(120)
    static let requestTimeout: Duration = .seconds(8)

    /// Call only after ENDLIST is acknowledged. Never shorten the grace to fit
    /// the shutdown budget: leave completion to YouTube's auto-stop instead.
    static func wait(
        deadline: ContinuousClock.Instant,
        now: @Sendable () -> ContinuousClock.Instant = { .now },
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> ContinuousClock.Instant {
        try Task.checkCancellation()
        let readyAt = now().advanced(by: duration)
        guard readyAt < deadline else { throw URLError(.timedOut) }
        try await sleep(duration)
        try Task.checkCancellation()
        let resumedAt = now()
        guard resumedAt < deadline else { throw URLError(.timedOut) }
        return min(deadline, resumedAt.advanced(by: requestTimeout))
    }
}

actor StreamingActor {
    private var appState: AppState?
    private var state: StreamSessionState = .idle
    private var mediaIntakeActive = false
    private var isHandlingRuntimeFailure = false
    private var outputPlan: StreamOutputPlan?
    private var youTubeCompletionTarget: YouTubeBroadcastCompletionTarget?
    private var youTubeHealthTarget: YouTubeHealthTarget?

    func setAppState(_ appState: AppState) {
        self.appState = appState
    }

    func presentAlert(_ message: String) async {
        let appState = self.appState
        await MainActor.run {
            appState?.activeAlert = message
        }
    }

    func beginPreparing() async throws {
        switch state {
        case .idle, .failed:
            mediaIntakeActive = false
            outputPlan = nil
            youTubeCompletionTarget = nil
            youTubeHealthTarget = nil
            await transition(to: .preparing)
        case .preparing, .live, .stopping:
            throw StreamSessionError.sessionBusy(state)
        }
    }

    func markLive() async throws {
        guard state == .preparing else {
            throw StreamSessionError.invalidTransition(from: state, to: .live)
        }
        mediaIntakeActive = true
        await transition(to: .live)
    }

    func setOutputPlan(_ outputPlan: StreamOutputPlan) {
        self.outputPlan = outputPlan
    }

    func setYouTubeBroadcast(
        id: String?, status: String?, completionTarget: YouTubeBroadcastCompletionTarget? = nil,
        healthTarget: YouTubeHealthTarget? = nil
    ) async {
        youTubeCompletionTarget = completionTarget
        youTubeHealthTarget = healthTarget
        let appState = self.appState
        await MainActor.run {
            appState?.isYouTubeSignedIn = id != nil
            appState?.youtubeBroadcastId = id
            appState?.youtubeStatus = status
            appState?.youtubeHealth.configure(healthTarget)
        }
    }

    func activeOutputPlan() -> StreamOutputPlan? {
        outputPlan
    }

    func activeYouTubeCompletionTarget() -> YouTubeBroadcastCompletionTarget? {
        youTubeCompletionTarget
    }

    func activeYouTubeHealthTarget() -> YouTubeHealthTarget? {
        youTubeHealthTarget
    }

    func confirmYouTubeCompletion(_ target: YouTubeBroadcastCompletionTarget) async {
        guard state == .stopping, youTubeCompletionTarget == target else { return }
        let appState = self.appState
        await MainActor.run {
            guard appState?.youtubeBroadcastId == target.id else { return }
            appState?.youtubeStatus = "complete"
        }
    }

    func beginStopping() async -> Bool {
        switch state {
        case .preparing, .live:
            await transition(to: .stopping)
            return true
        case .idle, .failed, .stopping:
            return false
        }
    }

    func closeMediaIntake() {
        mediaIntakeActive = false
    }

    func completeStop() async {
        mediaIntakeActive = false
        isHandlingRuntimeFailure = false
        outputPlan = nil
        youTubeCompletionTarget = nil
        youTubeHealthTarget = nil
        await transition(to: .idle)
    }

    func fail(_ error: Error) async {
        mediaIntakeActive = false
        isHandlingRuntimeFailure = false
        outputPlan = nil
        youTubeCompletionTarget = nil
        youTubeHealthTarget = nil
        await transition(to: .failed(error.localizedDescription))
    }

    func claimRuntimeFailure() -> Bool {
        guard !isHandlingRuntimeFailure else { return false }
        switch state {
        case .preparing, .live:
            isHandlingRuntimeFailure = true
            return true
        case .idle, .stopping, .failed:
            return false
        }
    }

    func sessionState() -> StreamSessionState {
        state
    }

    func setStreamHealth(_ health: StreamHealth) async {
        let appState = self.appState
        await MainActor.run {
            appState?.streamHealth = health
        }
    }

    func getStreamHealth() async -> StreamHealth {
        let appState = self.appState
        return await appState?.streamHealth ?? .awaiting
    }

    func isStreaming() async -> Bool {
        mediaIntakeActive
    }

    func toggleBatterySaving() async {
        let appState = self.appState
        await MainActor.run {
            appState?.isBatterySavingOn.toggle()
        }
    }

    func refreshCameraView() async {
        let appState = self.appState
        await MainActor.run {
            appState?.refreshCameraView()
        }
    }

    func getMonitor() async -> Monitor {
        let appState = self.appState
        return await appState?.activeMonitor ?? DEFAULT_MONITOR
    }

    func isBatterySavingOn() async -> Bool {
        await appState?.isBatterySavingOn ?? false
    }

    private func transition(to newState: StreamSessionState) async {
        state = newState
        let appState = self.appState
        await MainActor.run {
            appState?.setStreamSessionState(newState)
        }
    }
}

actor StreamCommandQueue {
    private var tail: Task<Void, Never>?

    func run<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let predecessor = tail
        let operationTask = Task<Result, Error> {
            if let predecessor {
                await predecessor.value
            }
            return try await operation()
        }
        tail = Task {
            _ = try? await operationTask.value
        }
        return try await operationTask.value
    }
}

final class Streamer: Sendable {
    public static let shared = Streamer()
    private let streamingActor = StreamingActor()
    private let commandQueue = StreamCommandQueue()
    private static let streamIDFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    static func makeStreamID(at date: Date = Date(), uuid: UUID = UUID()) -> String {
        let suffix = uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        return "\(streamIDFormatter.string(from: date))_\(suffix)"
    }
    
    func setAppState(_ appState: AppState) async {
        await self.streamingActor.setAppState(appState)
    }
    func cycleSessions() async throws {
        guard !CommandLine.arguments.contains("-ui-testing") else { return }
        let outputting = await CaptureDirector.shared.isOutputting()
        if outputting {
            await CaptureDirector.shared.stopOutput()
        }
        await FrameGrabber.shared.resetTinkerer()
        try await CaptureDirector.shared.cycleSessions()
        await streamingActor.refreshCameraView()
        OverlayBundler.shared.refreshCombinedImage()
        if outputting {
            try await CaptureDirector.shared.startOutput()
        }
    }
    func startSessions() async throws {
        try await CaptureDirector.shared.startSessions()
    }
    func stopSessions() async {
        await CaptureDirector.shared.stopSessions()
    }
    func startStream(streamID: String) async throws {
        try await commandQueue.run { [self] in
            try await performStart(streamID: streamID)
        }
    }

    func endStream(
        resumePreviewAfterStop: Bool = true,
        // Up to 120s to drain, then 120s observation and a bounded API request.
        shutdownTimeout: TimeInterval = 260
    ) async throws -> StreamStopResult {
        try await commandQueue.run { [self] in
            try await performStop(
                resumePreviewAfterStop: resumePreviewAfterStop,
                shutdownTimeout: shutdownTimeout
            )
        }
    }

    func handleRuntimeFailure(_ error: Error) async {
        guard await streamingActor.claimRuntimeFailure() else {
            await streamingActor.presentAlert(error.localizedDescription)
            return
        }
        LOG("Streaming pipeline failed: \(error.localizedDescription)", level: .error)
        await streamingActor.setStreamHealth(.unusable)
        do {
            _ = try await endStream()
            await streamingActor.fail(error)
        } catch {
            await streamingActor.fail(error)
        }
    }

    func handleCaptureSessionInterruption() async {
        let state = await streamingActor.sessionState()
        switch state {
        case .preparing, .live:
            let appIsNotActive = await MainActor.run {
                UIApplication.shared.applicationState != .active
            }
            if appIsNotActive {
                LOG("Camera session paused while Tubeist became inactive", level: .debug)
            } else {
                await handleRuntimeFailure(
                    CaptureSetupError.configuration("The camera session was interrupted")
                )
            }
        case .idle, .stopping, .failed:
            // iOS normally interrupts an idle preview when the app moves to the
            // background. The session resumes on return, so this is not an
            // end-user failure and must not be promoted to an alert.
            LOG("Camera preview session was interrupted", level: .debug)
        }
    }

    func handleMediaServicesReset() async {
        let resetError = CaptureSetupError.configuration("Camera media services were reset")
        await handleRuntimeFailure(resetError)
        do {
            try await cycleSessions()
            await streamingActor.presentAlert(
                "Camera media services were reset. Capture has been restored; review the preview before restarting."
            )
        } catch {
            await streamingActor.presentAlert(
                "Camera media services could not be restored: \(error.localizedDescription)"
            )
        }
    }

    private func performStart(streamID: String) async throws {
        try await streamingActor.beginPreparing()
        var packagingStarted = false
        var soundStarted = false
        var videoStarted = false
        var outputStarted = false

        do {
            guard await !ContentPackager.shared.isPackaging() else {
                throw ContentPackagingError.alreadyEncoding
            }
            let outputPlan = try StreamOutputPlan.resolve(
                stream: Settings.stream,
                record: Settings.record
            )
            await streamingActor.setOutputPlan(outputPlan)
            try await prepareEncodedOutput(streamID: streamID, plan: outputPlan)
            try await ContentPackager.shared.beginPackaging(
                stream: outputPlan.routesEncodedFragments,
                record: outputPlan.recordsLocally
            )
            packagingStarted = true
            await SoundGrabber.shared.commenceGrabbing()
            soundStarted = true
            await FrameGrabber.shared.commenceGrabbing()
            videoStarted = true
            await FrameGrabber.shared.resetDroppedFrameCount()
            try await CaptureDirector.shared.startOutput()
            outputStarted = true
            try await streamingActor.markLive()
        } catch {
            if outputStarted {
                await CaptureDirector.shared.stopOutput()
            }
            if videoStarted {
                await FrameGrabber.shared.terminateGrabbing()
            }
            if soundStarted {
                await SoundGrabber.shared.terminateGrabbing()
            }
            if packagingStarted {
                _ = try? await ContentPackager.shared.endPackaging()
            }
            await EncodedOutputRouter.shared.cancel()
            await streamingActor.fail(error)
            throw error
        }
    }

    private func performStop(
        resumePreviewAfterStop: Bool,
        shutdownTimeout: TimeInterval
    ) async throws -> StreamStopResult {
        guard await streamingActor.beginStopping() else {
            return .alreadyIdle
        }
        let clock = ContinuousClock()
        let stoppedAt = clock.now
        let shutdownDeadline = stoppedAt.advanced(by: .seconds(max(1, shutdownTimeout)))
        // Longer observation must not increase how long stalled uploads drain.
        let deadline = min(shutdownDeadline, stoppedAt.advanced(by: .seconds(120)))
        let shutdownMonitor = await YouTubeShutdownMonitor(stoppedAt: stoppedAt)
        let healthTarget = await streamingActor.activeYouTubeHealthTarget()
        let observationTask: Task<Void, Never>? = healthTarget.map { target in
            Task { @MainActor in
                let service = YouTubeService(diagnostics: YouTubeDiagnostics().forStatusMonitoring())
                await shutdownMonitor.run(target: target, fetchHealth: service.fetchIngestHealth,
                    fetchBroadcast: service.fetchBroadcastStatus)
            }
        }
        defer { observationTask?.cancel() }
        if healthTarget != nil {
            await shutdownMonitor.event("Stop requested; draining media; observing YouTube every 5 seconds", level: .info)
        }
        await ContentPackager.shared.beginFinalization()
        let outputPlan = await streamingActor.activeOutputPlan()
        let monitor = await streamingActor.getMonitor()

        // Audio is effectively real-time, while camera stabilization can delay
        // video presentation timestamps. Freeze audio at Stop, then keep only
        // video capture alive until it reaches that same instant. Waiting while
        // both tracks continued (the old behavior) could never close the gap.
        let stopTimestamp = await CaptureDirector.shared.beginOutputFinalization()
        var captureFailures: [String] = []
        if let stopTimestamp {
            let maximumCatchUpDeadline = clock.now.advanced(
                by: .seconds(CaptureTailAlignment.maximumVideoCatchUpSeconds)
            )
            let catchUpDeadline = min(deadline, maximumCatchUpDeadline)
            var videoTimestamp = await FrameGrabber.shared.getCurrentPresentationTimestamp()
            while !CaptureTailAlignment.videoHasReached(
                stopTimestamp: stopTimestamp,
                videoTimestamp: videoTimestamp
            ), clock.now < catchUpDeadline {
                do {
                    let remaining = max(.zero, clock.now.duration(to: catchUpDeadline))
                    try await Task.sleep(for: min(.milliseconds(10), remaining))
                } catch {
                    break
                }
                videoTimestamp = await FrameGrabber.shared.getCurrentPresentationTimestamp()
            }
            if !CaptureTailAlignment.videoHasReached(
                stopTimestamp: stopTimestamp,
                videoTimestamp: videoTimestamp
            ) {
                captureFailures.append(
                    "Stabilized video did not reach the Stop timestamp before its alignment deadline"
                )
                LOG(
                    "Stabilized video did not reach the Stop timestamp before capture was detached",
                    level: .error
                )
            }
        } else {
            LOG(
                "The capture clock was unavailable during Stop; detaching video without tail alignment",
                level: .warning
            )
        }
        await CaptureDirector.shared.finishOutputFinalization()

        // Detach capture callbacks first, then drain every sample already
        // accepted by the bounded mailboxes before closing media intake.
        async let framesDrained = FrameGrabber.shared.drainSubmittedFrames(deadline: deadline)
        async let audioDrained = SoundGrabber.shared.drainSubmittedAudio(deadline: deadline)
        let captureDrainResults = await (framesDrained, audioDrained)
        // Capture is detached, so this includes the stream's final frames and
        // excludes any output preview that resumes after Stop.
        await FrameGrabber.shared.logDroppedFrameCount()
        switch captureDrainResults {
        case (true, true):
            break
        case (false, true):
            captureFailures.append("Accepted video samples did not drain before the shutdown deadline")
        case (true, false):
            captureFailures.append("Accepted audio samples did not drain before the shutdown deadline")
        case (false, false):
            captureFailures.append("Accepted video and audio samples did not drain before the shutdown deadline")
        }
        let captureStatus: ShutdownComponentStatus = captureFailures.isEmpty
            ? .completed
            : .failed(captureFailures.joined(separator: "; "))
        await streamingActor.closeMediaIntake()
        let savingBattery = await streamingActor.isBatterySavingOn()
        let resumeOutputPreview = monitor == .output && resumePreviewAfterStop && !savingBattery
        if !resumeOutputPreview {
            await FrameGrabber.shared.terminateGrabbing()
        }
        await SoundGrabber.shared.terminateGrabbing()
        var packagingReport = ContentPackagingShutdownReport.notRequested
        do {
            packagingReport = try await ContentPackager.shared.endPackaging(deadline: deadline)
        } catch let error as ContentPackagingShutdownError {
            packagingReport = error.report
            LOG("Local output shutdown failed: \(error.localizedDescription)", level: .error)
        } catch {
            packagingReport = ContentPackagingShutdownReport(
                mediaEncoding: .failed(error.localizedDescription),
                fragmentDispatch: .notRequested,
                recording: outputPlan?.recordsLocally == true
                    ? .failed("Recording completion could not be determined")
                    : .notRequested
            )
            LOG("Local output shutdown failed: \(error.localizedDescription)", level: .error)
        }
        var youTubeStatus: ShutdownComponentStatus = outputPlan?.streamsToYouTube == true
            ? .completed
            : .notRequested
        var endListAcknowledged = false
        do {
            endListAcknowledged = try await EncodedOutputRouter.shared.finish(deadline: deadline)
            if endListAcknowledged {
                await shutdownMonitor.endListAcknowledged()
            }
        } catch {
            youTubeStatus = .failed(error.localizedDescription)
            LOG("Encoded output shutdown failed: \(error.localizedDescription)", level: .error)
        }
        if endListAcknowledged,
           let target = await streamingActor.activeYouTubeCompletionTarget() {
            do {
                let completionDeadline = try await YouTubeCompletionGrace.wait(deadline: shutdownDeadline)
                observationTask?.cancel()
                if await shutdownMonitor.observedCompletion {
                    await shutdownMonitor.event("Observation finished; broadcast already complete; no completion request needed", level: .info)
                } else {
                    await shutdownMonitor.event("120-second observation finished; requesting broadcast completion", level: .info)
                    let service = await YouTubeService()
                    try await service.completeBroadcastAfterUpload(
                        target, deadline: completionDeadline
                    )
                    await shutdownMonitor.event("Broadcast completion request confirmed", level: .info)
                }
                await streamingActor.confirmYouTubeCompletion(target)
            } catch {
                // Uploads and local recording are already finalized. Leave the
                // remote status truthful and let auto-stop/polling finish it.
                await shutdownMonitor.event("Completion was not confirmed; leaving YouTube auto-stop in control (\(YouTubeDiagnostics.failure(error)))", level: .warning)
            }
        }
        let result = StreamStopResult(
            outcome: .stopped,
            captureIntake: captureStatus,
            packaging: packagingReport,
            youTubeUpload: youTubeStatus
        )
        if !result.succeeded {
            let shutdownError = StreamShutdownError(report: result)
            await streamingActor.setStreamHealth(.unusable)
            await streamingActor.fail(shutdownError)
            throw shutdownError
        }
        await streamingActor.completeStop()
        if resumeOutputPreview {
            do {
                try await CaptureDirector.shared.startOutput()
            } catch {
                LOG("Stream stopped, but output preview could not resume: \(error.localizedDescription)", level: .error)
            }
        }
        return result
    }
    func isStreaming() async -> Bool {
        await streamingActor.isStreaming()
    }
    func sessionState() async -> StreamSessionState {
        await streamingActor.sessionState()
    }
    func setStreamHealth(_ health: StreamHealth) async {
        await streamingActor.setStreamHealth(health)
    }
    func getStreamHealth() async -> StreamHealth {
        await streamingActor.getStreamHealth()
    }
    func toggleBatterySaving() async {
        await streamingActor.toggleBatterySaving()
    }
    func getMonitor() async -> Monitor {
        await streamingActor.getMonitor()
    }
    func setMonitor(_ monitor: Monitor) async {
        // Preview setup must not reopen capture callbacks while Start or Stop
        // is suspended in encoding, network preflight, or finalization.
        try? await commandQueue.run { [self] in
            await performMonitorChange(monitor)
        }
    }

    private func performMonitorChange(_ monitor: Monitor) async {
        LOG("Setting monitor to \(monitor)", level: .debug)
        let savingBattery = await streamingActor.isBatterySavingOn()
        if monitor == .output, !savingBattery, await !isStreaming() {
            LOG("Starting half the streaming pipeline", level: .debug)
            await FrameGrabber.shared.commenceGrabbing()
            do {
                try await CaptureDirector.shared.startOutput()
            } catch {
                await FrameGrabber.shared.terminateGrabbing()
                LOG("Could not start output monitoring: \(error.localizedDescription)", level: .error)
            }
        }
        else if monitor == .camera || savingBattery, await !isStreaming() {
            LOG("Stopping half the streaming pipeline", level: .debug)
            await CaptureDirector.shared.stopOutput()
            await FrameGrabber.shared.terminateGrabbing()
        }
    }

    private func prepareEncodedOutput(streamID: String, plan: StreamOutputPlan) async throws {
        guard plan.streamsToYouTube else {
            await EncodedOutputRouter.shared.prepareForRecordingOnly()
            return
        }

#if DEBUG
        if HLSLiveDiagnostic.isRequested {
            let endpoint = try await HLSLiveDiagnostic.shared.takeEndpoint()
            // This explicit diagnostic broadcast is managed in Studio. Do not
            // prepare or complete a different broadcast using saved credentials.
            await streamingActor.setYouTubeBroadcast(id: nil, status: nil)
            let model = await MainActor.run { UIDevice.current.model.replacingOccurrences(of: " ", with: "_") }
            try await EncodedOutputRouter.shared.prepareYouTube(
                endpoint: endpoint, sessionIdentifier: streamID,
                userAgent: "Apple / \(model) / Tubeist-\(Bundle.main.appVersion ?? "unknown")"
            )
            return
        }
#endif

        guard let streamKey = Settings.streamKey, !streamKey.isEmpty else {
            throw StreamStartError.missingStreamKey
        }

        let endingPolicy = Settings.hlsStreamEndingPolicy
        if endingPolicy == .manualDiagnostic, Settings.youtubeRefreshToken == nil {
            // Without API access we cannot guarantee auto-stop is disabled.
            throw StreamStartError.endingTestRequiresSignIn
        }
        let endpoint: YouTubeHLSEndpoint
        if Settings.youtubeRefreshToken != nil {
            let service = await YouTubeService()
            let preferences = Settings.youtubeBroadcastPreferences
            let thumbnailData = preferences == nil
                ? nil
                : try Settings.loadYouTubeThumbnailData()
            let preparation = try await service.prepareForStreaming(
                streamKey: streamKey,
                preferences: preferences,
                thumbnailData: thumbnailData,
                endingPolicy: endingPolicy
            )
            endpoint = preparation.endpoint
            await streamingActor.setYouTubeBroadcast(
                id: preparation.broadcast.id,
                status: preparation.broadcast.lifeCycleStatus,
                completionTarget: preparation.completionTarget,
                healthTarget: preparation.healthTarget
            )
        } else {
            endpoint = try YouTubeHLSEndpoint.manualPrimary(streamKey: streamKey)
            await streamingActor.setYouTubeBroadcast(id: nil, status: nil)
        }
        let model = await MainActor.run { UIDevice.current.model.replacingOccurrences(of: " ", with: "_") }
        let userAgent = "Apple / \(model) / Tubeist-\(Bundle.main.appVersion ?? "unknown")"
        try await EncodedOutputRouter.shared.prepareYouTube(
            endpoint: endpoint,
            sessionIdentifier: streamID,
            userAgent: userAgent,
            endingPolicy: endingPolicy
        )
        if endingPolicy == .manualDiagnostic {
            LOG("YouTube ending test: auto-stop disabled; no ENDLIST or automatic completion. End this broadcast manually in YouTube Studio.", level: .info)
        }
    }
}

enum StreamStartError: LocalizedError, Equatable {
    case missingStreamKey
    case noOutputSelected
    case endingTestRequiresSignIn

    var errorDescription: String? {
        switch self {
        case .missingStreamKey: "Enter a YouTube HLS stream key before starting"
        case .noOutputSelected: "Enable YouTube streaming, local recording, or both"
        case .endingTestRequiresSignIn: "Sign in to YouTube before using the stream ending test, or turn the test off in Settings"
        }
    }
}
