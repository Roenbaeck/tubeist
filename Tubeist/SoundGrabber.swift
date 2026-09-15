//
//  SoundGrabber.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2025-01-02.
//
import AVFoundation

private final class AudioCaptureIntake: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    func setEnabled(_ enabled: Bool) { lock.withLock { self.enabled = enabled } }
    func isEnabled() -> Bool { lock.withLock { enabled } }
}

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
    private let intake = AudioCaptureIntake()

    override init() {
        let soundGrabbing = SoundGrabbingActor()
        self.soundGrabbing = soundGrabbing
        self.soundMailbox = BoundedAsyncMailbox(
            policy: CaptureBuffering.audioPolicy, timing: { $0.mailboxTiming },
            onDrop: { submission in
                guard submission.shouldReport(every: 32) else { return }
                LOG("Dropped audio exceeding the capture buffer budget", level: .error)
                Task { await Streamer.shared.setStreamHealth(.unusable) }
            }
        ) { sampleBuffer in
            await soundGrabbing.process(sampleBuffer)
        }
        super.init()
    }
    
    func commenceGrabbing() async {
        if await !soundGrabbing.isActive() {
            await soundGrabbing.start()
            soundMailbox.resetDropCount()
            intake.setEnabled(true)
            LOG("Started grabbing sound", level: .debug)
        }
        else {
            LOG("Sound grabbing already started", level: .debug)
        }
    }
    func terminateGrabbing() async {
        intake.setEnabled(false)
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
        // Output preview also attaches the microphone delegate. It needs no
        // queued recording audio and must not report audio-overflow failures.
        guard intake.isEnabled() else { return }
        nonisolated(unsafe) let sendableSampleBuffer = sampleBuffer
        soundMailbox.submit(SendableSampleBuffer(value: sendableSampleBuffer))
    }
}
