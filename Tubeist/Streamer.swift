//
//  Streamer.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-06.
//
import CoreMedia

enum StreamHealth {
    case silenced   // When stream is not running
    case awaiting   // Health has not been determined
    case unusable   // Stream is too bad to watch
    case degraded   // Noticeable quality issues
    case pristine   // Perfect viewing experience
}

actor StreamingActor {
    private var appState: AppState?
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
            OutputMonitorView.isBatterySavingOn = await appState?.isBatterySavingOn ?? false
        }
    }
    func refreshCameraView() {
        Task { @MainActor in
            await appState?.refreshCameraView()
        }
    }
    func getMonitor() async -> Monitor {
        await appState?.activeMonitor ?? DEFAULT_MONITOR
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
        // session time is close to real time
        // presentation time can be earlier because of camera stabilization
        if let sessionTime = await CaptureDirector.shared.getSessionTime(),
           let presentationTime = await FrameGrabber.shared.getCurrentPresentationTimestamp() {
            let difference = CMTimeSubtract(sessionTime, presentationTime)
            let duration = CMTimeGetSeconds(difference)
            LOG("Sleeping \(duration) seconds to await late frames", level: .debug)
            if duration > 0 {
                do {
                    try await Task.sleep(for: .seconds(duration))
                }
                catch {
                    LOG("Sleeping to await late frames interrupted", level: .warning)
                }
            }
        }
        
        await streamingActor.pause()
        if await streamingActor.getMonitor() == .camera {
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
    func getMonitor() async -> Monitor {
        await streamingActor.getMonitor()
    }
    func setMonitor(_ monitor: Monitor) async {
        LOG("Setting monitor to \(monitor)", level: .debug)
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
}
