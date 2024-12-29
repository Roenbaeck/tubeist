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
    func getMonitor() async -> Monitor {
        await appState?.activeMonitor ?? .camera
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
    public static let shared = Streamer()
    private let streamingActor = StreamingActor()
    
    func setAppState(_ appState: AppState) {
        Task {
            await self.streamingActor.setAppState(appState)
        }
    }
    func cycleCamera() async {
        await CameraMonitor.shared.stopCamera()
        await CameraMonitor.shared.startCamera()
        await streamingActor.refreshCameraView()
    }
    func startCamera() async {
        await CameraMonitor.shared.startCamera()
    }
    func stopCamera() async {
        await CameraMonitor.shared.stopCamera()
    }
    func startStream() async {
        await FragmentPusher.shared.immediatePreparation()
        await AssetInterceptor.shared.beginIntercepting()
        if await streamingActor.getMonitor() == .camera {
            await FrameGrabber.shared.commenceGrabbing()
            await CameraMonitor.shared.startOutput()
        }
        await streamingActor.run()
    }
    func endStream() async {
        await streamingActor.pause()
        if await streamingActor.getMonitor() == .camera {
            await CameraMonitor.shared.stopOutput()
            await FrameGrabber.shared.terminateGrabbing()
        }
        await AssetInterceptor.shared.endIntercepting()
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
        if monitor == .output, await !isStreaming() {
            LOG("Starting half the streaming pipeline", level: .debug)
            await FrameGrabber.shared.commenceGrabbing()
            await CameraMonitor.shared.startOutput()
        }
        else if monitor == .camera, await !isStreaming() {
            LOG("Stopping half the streaming pipeline", level: .debug)
            await CameraMonitor.shared.stopOutput()
            await FrameGrabber.shared.terminateGrabbing()
        }
    }
    func getMonitor() async -> Monitor {
        await streamingActor.getMonitor()
    }
}
