//
//  SoundGrabber.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2025-01-02.
//
import AVFoundation

final class SoundGrabber: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
    @PipelineActor public static let shared = SoundGrabber()
    private let soundMailbox: BoundedAsyncMailbox<SendableSampleBuffer>

    override init() {
        self.soundMailbox = BoundedAsyncMailbox(
            policy: CaptureBuffering.audioPolicy, timing: { $0.mailboxTiming },
            onDrop: { submission in
                guard submission.shouldReport(every: 32) else { return }
                LOG("Dropped audio exceeding the capture buffer budget", level: .error)
                Task { await Streamer.shared.setStreamHealth(.unusable) }
            }
        ) { sampleBuffer in
            await ContentPackager.shared.appendCapturedSample(sampleBuffer, kind: .audio)
        }
        super.init()
    }
    
    func resetDropCount() {
        soundMailbox.resetDropCount()
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
        let sample = SendableSampleBuffer(capturing: sampleBuffer)
        guard sample.sessionID != nil else { return }
        soundMailbox.submit(sample)
    }
}
