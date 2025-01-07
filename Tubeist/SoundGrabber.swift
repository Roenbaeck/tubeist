//
//  SoundGrabber.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2025-01-02.
//
import AVFoundation

private actor SoundGrabbingActor {
    private var grabbingSound: Bool = false
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
        if await !soundGrabbing.isActive() {
            await soundGrabbing.start()
            LOG("Started grabbing sound", level: .debug)
        }
        else {
            LOG("Sound grabbing already started", level: .debug)
        }
    }
    func terminateGrabbing() async {
        if await soundGrabbing.isActive() {
            await soundGrabbing.stop()
            LOG("Stopped grabbing sound", level: .debug)
        }
        else {
            LOG("Sound grabbing already stopped", level: .debug)
        }
    }
    
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        nonisolated(unsafe) let sendableSampleBuffer = sampleBuffer
        PipelineActor.queue.async {
            Task { @PipelineActor [sendableSampleBuffer] in
                if await self.soundGrabbing.isActive(), await Streamer.shared.isStreaming() {
                    await ContentPackager.shared.appendAudioSampleBuffer(sendableSampleBuffer)
                }
            }
        }
    }
}
