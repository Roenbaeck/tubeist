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

    func process(_ wrappedSampleBuffer: SendableSampleBuffer) async {
        guard grabbingSound, await Streamer.shared.isStreaming() else {
            return
        }
        nonisolated(unsafe) let sampleBuffer = wrappedSampleBuffer.value
        do {
            try await ContentPackager.shared.appendAudioSampleBuffer(sampleBuffer)
        } catch {
            Task {
                await Streamer.shared.handleRuntimeFailure(error)
            }
        }
    }
}

final class SoundGrabber: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
    @PipelineActor public static let shared = SoundGrabber()
    private let soundGrabbing: SoundGrabbingActor
    private let soundMailbox: BoundedAsyncMailbox<SendableSampleBuffer>

    override init() {
        let soundGrabbing = SoundGrabbingActor()
        self.soundGrabbing = soundGrabbing
        self.soundMailbox = BoundedAsyncMailbox(policy: .fifo(limit: 32)) { sampleBuffer in
            await soundGrabbing.process(sampleBuffer)
        }
        super.init()
    }
    
    func commenceGrabbing() async {
        if await !soundGrabbing.isActive() {
            await soundGrabbing.start()
            soundMailbox.resetDropCount()
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
    func drainSubmittedAudio() async {
        await soundMailbox.waitUntilIdle()
    }
    func drainSubmittedAudio(deadline: ContinuousClock.Instant) async -> Bool {
        await soundMailbox.waitUntilIdle(deadline: deadline)
    }
    
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        nonisolated(unsafe) let sendableSampleBuffer = sampleBuffer
        let submission = soundMailbox.submit(SendableSampleBuffer(value: sendableSampleBuffer))
        if submission.dropped, submission.totalDropped % 32 == 1 {
            LOG("Dropped queued audio work to keep capture memory bounded", level: .error)
            Task {
                await Streamer.shared.setStreamHealth(.unusable)
            }
        }
    }
}
