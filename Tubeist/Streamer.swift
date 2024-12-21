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
    func isStreaming() async -> Bool {
        await appState?.isStreamActive ?? false
    }
}

final class Streamer: Sendable {
    public static let shared = Streamer()
    private let streamingActor = StreamingActor()
    private let cameraMonitor = CameraMonitor.shared
    private let frameGrabber = FrameGrabber.shared
    private let assetInterceptor = AssetInterceptor.shared
    private let fragmentPusher = FragmentPusher.shared
    
    func setAppState(_ appState: AppState) {
        Task {
            await self.streamingActor.setAppState(appState)
        }
    }
    func startCamera() {
        Task {
            await cameraMonitor.startCamera()
        }
    }
    func stopCamera() {
        Task {
            await cameraMonitor.stopCamera()
        }
    }
    func startStream() {
        Task {
            if await !cameraMonitor.isRunning() {
                await cameraMonitor.startCamera()
            }
            await fragmentPusher.immediatePreparation()
            await assetInterceptor.beginIntercepting()
            await frameGrabber.commenceGrabbing()
            await cameraMonitor.startOutput();
            await streamingActor.run()
        }
    }
    func endStream() {
        Task {
            await streamingActor.pause()
            await cameraMonitor.stopOutput()
            await frameGrabber.terminateGrabbing()
            await assetInterceptor.endIntercepting()
            await fragmentPusher.gracefulShutdown()
        }
    }
    func isStreaming() async -> Bool {
        await streamingActor.isStreaming()
    }
    func setStreamHealth(_ health: StreamHealth) {
        Task {
            await streamingActor.setStreamHealth(health)
        }
    }

}
