//
//  TSContentPackager.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2025-10-05.
//

import AVFoundation
import CoreMedia
import VideoToolbox

/// Streaming packager that encodes raw video/audio into HEVC+AAC and muxes
/// them directly into MPEG-TS segments, bypassing AVAssetWriter entirely.
///
/// This produces segments that YouTube's HLS ingest accepts without any relay-side
/// remuxing. The pipeline is:
///   CVPixelBuffer → VideoEncoder (VTCompressionSession/HEVC) →
///   CMSampleBuffer PCM → AudioEncoder (AudioConverter/AAC) →
///   TSSegmenter → MPEG-TS Fragment → FragmentPusher
///
/// Recording (MP4) is handled separately by ContentPackager via AVAssetWriter,
/// which receives the same raw sample buffers in parallel. This class never
/// writes to disk and does not own a RecordingActor.
@PipelineActor
final class TSContentPackager {
    static let shared = TSContentPackager()
    
    private let videoEncoder = VideoEncoder()
    private var audioEncoder: AudioEncoder?
    private let segmenter = TSSegmenter()
    private var isActive = false
    private var stream: Bool = false
    
    /// Initialises all sub-components and begins accepting sample buffers.
    ///
    /// The segmenter is wired first so that encoded frames can be forwarded
    /// into it as soon as the encoders start producing output.
    func beginPackaging() async {
        guard !isActive else {
            LOG("TS packager already active", level: .debug)
            return
        }

        // Initialize here; although AudioEncoder is @AudioActor, 
        // the reference itself can be held by PipelineActor.
        let encoder = AudioEncoder()
        self.audioEncoder = encoder
        
        let preset = Settings.selectedPreset

        // Setup within the actor context to capture the weak self reference correctly.
        // The closure bridges from @AudioActor (where it's called) back to @PipelineActor.
        await encoder.setup(
            sampleRate: AUDIO_SAMPLE_RATE,
            channels: preset.audioChannels,
            bitrate: preset.audioBitrate
        ) { [weak self] frame in
            Task { @PipelineActor in
                self?.segmenter.addAudioFrame(frame)
            }
        }
        
        let frameRate = preset.frameRate
        let keyframeInterval = preset.keyframeInterval
        // Match the segment duration logic used by AVAssetWriter to keep the
        // two paths numerically consistent when both are active
        let adjustedFragmentDuration = frameRate / trunc(frameRate / FRAGMENT_DURATION)
        
        stream = Settings.stream
        
        // Wire the segmenter first: its closure is called by the encoders' callbacks
        // which may fire on PipelineActor before setup() returns.
        // sampleRate is intentionally omitted: TSSegmenter reads it from each
        // EncodedAudioFrame, which AudioEncoder populates with the device's
        // actual native rate (detected lazily on the first capture buffer).
        segmenter.setup(
            segmentDuration: adjustedFragmentDuration,
            audioChannels: preset.audioChannels
        ) { [weak self] fragment in
            // Already on PipelineActor (TSSegmenter is @PipelineActor)
            guard let self else { return }
            if self.stream {
                Task {
                    await FragmentPusher.shared.addFragment(fragment)
                    await FragmentPusher.shared.uploadFragment(attempt: 1)
                }
            }
        }
        
        // Encoded video frames are forwarded directly into the segmenter.
        // The callback fires on PipelineActor (bridged from the VT thread).
        videoEncoder.setup(
            width: preset.width,
            height: preset.height,
            frameRate: frameRate,
            bitrate: preset.videoBitrate,
            keyframeInterval: keyframeInterval
        ) { [weak self] frame in
            self?.segmenter.addVideoFrame(frame)
        }
        
        // Encoded audio frames are forwarded directly into the segmenter.
        // The converter callback fires synchronously on AudioActor.
        audioEncoder.setup(
            sampleRate: AUDIO_SAMPLE_RATE,
            channels: preset.audioChannels,
            bitrate: preset.audioBitrate
        ) { [weak self] frame in
            // Bridge from AudioActor to PipelineActor
            Task { @PipelineActor in
                self?.segmenter.addAudioFrame(frame)
            }
        }
        
        isActive = true
        LOG("TS content packager started", level: .debug)
    }
    
    /// Flushes encoders, finalizes the last segment, and stops accepting buffers.
    func endPackaging() async {
        guard isActive else {
            LOG("TS packager not active", level: .debug)
            return
        }
        isActive = false
        // Flush all pending encoded frames before finalizing the segment
        await videoEncoder.teardown()
        await audioEncoder.teardown()
        segmenter.finalize()
        LOG("TS content packager stopped", level: .debug)
    }
    
    /// Accepts a raw camera frame for encoding. The pixel buffer is extracted here
    /// rather than in VideoEncoder to keep format concerns at the boundary.
    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isActive else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            LOG("TSContentPackager: no pixel buffer in video sample", level: .error)
            return
        }
        // Pass the original PTS; VideoEncoder normalises it to start from zero
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        videoEncoder.encode(pixelBuffer: pixelBuffer, presentationTimeStamp: pts)
    }
    
    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isActive, let encoder = audioEncoder else { return }
        nonisolated(unsafe) let sendableBuffer = sampleBuffer
        Task { @AudioActor in
            await encoder.encode(sampleBuffer: sendableBuffer)
        }
    }
    
    /// Returns whether the packager is currently accepting sample buffers.
    func isPackaging() -> Bool {
        isActive
    }
}

