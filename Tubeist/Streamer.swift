//
//  Streamer.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-06.
//
import CoreMedia
import UIKit

enum StreamHealth {
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
    let recordsOriginalFMP4: Bool

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
            return StreamOutputPlan(streamsToYouTube: false, recordsOriginalFMP4: record)
        }
        return StreamOutputPlan(streamsToYouTube: true, recordsOriginalFMP4: record)
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

actor StreamingActor {
    private var appState: AppState?
    private var state: StreamSessionState = .idle
    private var mediaIntakeActive = false
    private var isHandlingRuntimeFailure = false
    private var outputPlan: StreamOutputPlan?

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

    func setYouTubeBroadcast(id: String?, status: String?) async {
        let appState = self.appState
        await MainActor.run {
            appState?.isYouTubeSignedIn = id != nil
            appState?.youtubeBroadcastId = id
            appState?.youtubeStatus = status
        }
    }

    func activeOutputPlan() -> StreamOutputPlan? {
        outputPlan
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
        await transition(to: .idle)
    }

    func fail(_ error: Error) async {
        mediaIntakeActive = false
        isHandlingRuntimeFailure = false
        outputPlan = nil
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
            OutputMonitorView.isBatterySavingOn = appState?.isBatterySavingOn ?? false
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
    @PipelineActor public static let shared = Streamer()
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
        shutdownTimeout: TimeInterval = 120
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
                throw ContentPackagingError.assetWriterAlreadyWriting
            }
            let outputPlan = try StreamOutputPlan.resolve(
                stream: Settings.stream,
                record: Settings.record
            )
            await streamingActor.setOutputPlan(outputPlan)
            try await prepareEncodedOutput(streamID: streamID, plan: outputPlan)
            try await ContentPackager.shared.beginPackaging(
                stream: outputPlan.routesEncodedFragments,
                record: outputPlan.recordsOriginalFMP4
            )
            packagingStarted = true
            await SoundGrabber.shared.commenceGrabbing()
            soundStarted = true
            await FrameGrabber.shared.commenceGrabbing()
            videoStarted = true
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
        let deadline = clock.now.advanced(by: .seconds(max(1, shutdownTimeout)))
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
        if monitor == .camera || !resumePreviewAfterStop {
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
                assetWriter: .failed(error.localizedDescription),
                fragmentDispatch: .notRequested,
                recording: outputPlan?.recordsOriginalFMP4 == true
                    ? .failed("Recording completion could not be determined")
                    : .notRequested
            )
            LOG("Local output shutdown failed: \(error.localizedDescription)", level: .error)
        }
        var youTubeStatus: ShutdownComponentStatus = outputPlan?.streamsToYouTube == true
            ? .completed
            : .notRequested
        do {
            try await EncodedOutputRouter.shared.finish(deadline: deadline)
        } catch {
            youTubeStatus = .failed(error.localizedDescription)
            LOG("Encoded output shutdown failed: \(error.localizedDescription)", level: .error)
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
        if monitor == .output, resumePreviewAfterStop {
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
        LOG("Setting monitor to \(monitor)", level: .debug)
        if monitor == .output, await !isStreaming() {
            LOG("Starting half the streaming pipeline", level: .debug)
            await FrameGrabber.shared.commenceGrabbing()
            do {
                try await CaptureDirector.shared.startOutput()
            } catch {
                await FrameGrabber.shared.terminateGrabbing()
                LOG("Could not start output monitoring: \(error.localizedDescription)", level: .error)
            }
        }
        else if monitor == .camera, await !isStreaming() {
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

        guard let streamKey = Settings.streamKey, !streamKey.isEmpty else {
            throw StreamStartError.missingStreamKey
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
                thumbnailData: thumbnailData
            )
            endpoint = preparation.endpoint
            await streamingActor.setYouTubeBroadcast(
                id: preparation.broadcast.id,
                status: preparation.broadcast.lifeCycleStatus
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
            userAgent: userAgent
        )
    }
}

enum StreamStartError: LocalizedError, Equatable {
    case missingStreamKey
    case noOutputSelected

    var errorDescription: String? {
        switch self {
        case .missingStreamKey: "Enter a YouTube HLS stream key before starting"
        case .noOutputSelected: "Enable YouTube streaming, local recording, or both"
        }
    }
}
