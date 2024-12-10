//
//  Streamer.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-06.
//

actor StreamingActor {
    private var _isStreaming: Bool = false
    func run() {
        _isStreaming = true
    }
    func pause() {
        _isStreaming = false
    }
    func isStreaming() -> Bool {
        _isStreaming
    }
}

final class Streamer: Sendable {
    public static let shared = Streamer()
    private let streamingActor = StreamingActor()
    private let cameraMonitor = CameraMonitor.shared
    private let frameGrabber = FrameGrabber.shared
    private let assetInterceptor = AssetInterceptor.shared
    private let fragmentPusher = FragmentPusher.shared
    
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
            await assetInterceptor.beginIntercepting()
            await cameraMonitor.startOutput();
            await streamingActor.run()
        }
    }
    func endStream() {
        Task {
            await streamingActor.pause()
            await cameraMonitor.stopOutput()
            await assetInterceptor.endIntercepting()
        }
    }
    func isStreaming() async -> Bool {
        await streamingActor.isStreaming()
    }
}
