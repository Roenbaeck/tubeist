//
//  Streamer.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-06.
//

enum StreamHealth {
    case silenced   // When stream is not running
    case awaiting   // Health has not been determined
    case unusable   // Stream is too bad to watch
    case degraded   // Noticeable quality issues
    case pristine   // Perfect viewing experience
}

actor StreamingActor {
    private var appState: AppState?
    private var activeMonitor: Monitor = DEFAULT_MONITOR
    func setAppState(_ appState: AppState) {
        self.appState = appState
    }
    func run() {
        Task { @MainActor in
            await appState?.isStreamActive = true
            await appState?.streamHealth = .awaiting
        }
    }
    func pause() {
        Task { @MainActor in
            await appState?.isStreamActive = false
        }
    }
    func setMonitor(_ monitor: Monitor) {
        activeMonitor = monitor
    }
    func getMonitor() -> Monitor {
        activeMonitor
    }
    func setStreamHealth(_ health: StreamHealth) {
        Task { @MainActor in
            await appState?.streamHealth = health
        }
    }
    func getStreamHealth() async -> StreamHealth {
        await appState?.streamHealth ?? .awaiting
    }
    func isStreaming() async -> Bool {
        await appState?.isStreamActive ?? false
    }
    func toggleBatterySaving() {
        Task { @MainActor in
            await appState?.isBatterySavingOn.toggle()
        }
    }
    func refreshCameraView() {
        Task { @MainActor in
            await appState?.refreshCameraView()
        }
    }
}

final class Streamer: Sendable {
    @PipelineActor public static let shared = Streamer()
    private let streamingActor = StreamingActor()
    
    func setAppState(_ appState: AppState) async {
        await self.streamingActor.setAppState(appState)
    }
    func cycleSessions() async {
        let outputting = await CaptureDirector.shared.isOutputting()
        if outputting {
            await CaptureDirector.shared.stopOutput()
        }
        await FrameGrabber.shared.resetTinkerer()
        await CaptureDirector.shared.cycleSessions()
        await streamingActor.refreshCameraView()
        OverlayBundler.shared.refreshCombinedImage()
        if outputting {
            await CaptureDirector.shared.startOutput()
        }
    }
    func startSessions() async {
        await CaptureDirector.shared.startSessions()
    }
    func stopSessions() async {
        await CaptureDirector.shared.stopSessions()
    }
    func startStream() async {
        await FragmentPusher.shared.immediatePreparation()
        await ContentPackager.shared.beginPackaging()
        await SoundGrabber.shared.commenceGrabbing()
        await FrameGrabber.shared.commenceGrabbing()
        await CaptureDirector.shared.startOutput()
        await streamingActor.run()
    }
    func endStream() async {
        await streamingActor.pause()
        if await getMonitor() == .camera {
            await CaptureDirector.shared.stopOutput()
            await FrameGrabber.shared.terminateGrabbing()
        }
        await SoundGrabber.shared.terminateGrabbing()
        await ContentPackager.shared.endPackaging()
        await FragmentPusher.shared.gracefulShutdown()
    }
    func isStreaming() async -> Bool {
        await streamingActor.isStreaming()
    }
    func setStreamHealth(_ health: StreamHealth) {
        Task {
            await streamingActor.setStreamHealth(health)
        }
    }
    func getStreamHealth() async -> StreamHealth {
        await streamingActor.getStreamHealth()
    }
    func toggleBatterySaving() async {
        await streamingActor.toggleBatterySaving()
    }
    
    func setMonitor(_ monitor: Monitor) async {
        LOG("Setting monitor to \(monitor)", level: .debug)
        await streamingActor.setMonitor(monitor)
        if monitor == .output, await !isStreaming() {
            LOG("Starting half the streaming pipeline", level: .debug)
            await FrameGrabber.shared.commenceGrabbing()
            await CaptureDirector.shared.startOutput()
        }
        else if monitor == .camera, await !isStreaming() {
            LOG("Stopping half the streaming pipeline", level: .debug)
            await CaptureDirector.shared.stopOutput()
            await FrameGrabber.shared.terminateGrabbing()
        }
    }
    func getMonitor() async -> Monitor {
        await streamingActor.getMonitor()
    }
}
