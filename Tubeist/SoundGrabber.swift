//
//  SoundGrabber.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2025-01-02.
//
@preconcurrency import AVFoundation

private actor SoundGrabbingActor {
    private var grabbingSound: Bool = true
    func start() {
        grabbingSound = true
    }
    func stop() {
        grabbingSound = false
    }
    func isActive() -> Bool {
        grabbingSound
    }
}

final class SoundGrabber: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
    @PipelineActor public static let shared = SoundGrabber()
    private let soundGrabbing = SoundGrabbingActor()
    
    func commenceGrabbing() async {
        await soundGrabbing.start()
    }
    func terminateGrabbing() async {
        await soundGrabbing.stop()
    }
    
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {        
        Task { @PipelineActor in
            if await self.soundGrabbing.isActive(), await Streamer.shared.isStreaming() {
                await AssetInterceptor.shared.appendAudioSampleBuffer(sampleBuffer)
            }
        }
    }
}
