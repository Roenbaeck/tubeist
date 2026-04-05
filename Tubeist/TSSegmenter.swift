//
//  TSSegmenter.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2025-10-05.
//

import Foundation
import CoreMedia

/// Collects encoded video and audio frames, muxes them into MPEG-TS packets via TSMuxer,
/// and emits keyframe-aligned segments as Fragment objects that can be passed directly
/// to FragmentPusher for upload.
///
/// Segment boundaries are always cut on video keyframes (IDR frames), ensuring every
/// segment is independently decodable. A slight undershoot (90% of target duration)
/// is accepted to keep the cut aligned to keyframes rather than forcing one early.
///
/// Audio frames that arrive before the first video keyframe are discarded, since a valid
/// TS segment must begin with PAT/PMT tables followed by video — mirrors the
/// pendingAudio pattern used in the AVAssetWriter path.
@PipelineActor
final class TSSegmenter {
    private var muxer = TSMuxer()
    private var currentSegment = Data()      // Accumulates TS packets for the current segment
    private var segmentDuration: Double = FRAGMENT_DURATION
    private var segmentStartPTS: Int64 = 0   // 90kHz PTS of the first video frame in this segment
    private var lastVideoPTS: Int64 = 0      // 90kHz PTS of the most recent video frame
    private var sequenceNumber: Int = -1     // Incremented each time a segment is emitted
    private var sampleRate: Double = AUDIO_SAMPLE_RATE
    private var audioChannels: Int = DEFAULT_AUDIO_CHANNELS
    private var isActive: Bool = false
    
    private var onSegment: ((Fragment) -> Void)?
    
    /// Configures the segmenter and resets all state. Must be called before any frames are added.
    /// - Parameters:
    ///   - segmentDuration: Target segment duration in seconds (may be adjusted for frame alignment).
    ///   - sampleRate: Audio sample rate, needed to build ADTS headers.
    ///   - audioChannels: Number of audio channels, needed to build ADTS headers.
    ///   - onSegment: Called whenever a complete segment is ready. Runs on PipelineActor.
    func setup(segmentDuration: Double, sampleRate: Double, audioChannels: Int,
               onSegment: @escaping (Fragment) -> Void) {
        self.segmentDuration = segmentDuration
        self.sampleRate = sampleRate
        self.audioChannels = audioChannels
        self.onSegment = onSegment
        self.muxer.reset()
        self.currentSegment = Data()
        self.sequenceNumber = -1
        self.segmentStartPTS = 0
        self.lastVideoPTS = 0
        self.isActive = true
        LOG("TSSegmenter configured: segment duration \(segmentDuration)s", level: .debug)
    }
    
    /// Accepts an encoded video frame and appends it to the current segment.
    ///
    /// On a keyframe, checks whether the accumulated duration has reached the target.
    /// If so, the current segment is emitted before starting a new one. Every segment
    /// begins with freshly generated PAT and PMT packets so it is self-contained.
    func addVideoFrame(_ frame: EncodedVideoFrame) {
        guard isActive else { return }
        
        // Cut a new segment on keyframes once enough time has elapsed
        if frame.isKeyFrame && !currentSegment.isEmpty {
            let elapsed = Double(frame.pts - segmentStartPTS) / 90000.0
            // Allow a 10% undershoot so we don't force a keyframe early
            if elapsed >= segmentDuration * 0.9 {
                emitSegment(duration: elapsed, isFinal: false)
            }
        }
        
        // Start a new segment: write PAT + PMT so the segment is self-contained
        if currentSegment.isEmpty {
            segmentStartPTS = frame.pts
            currentSegment.append(muxer.generatePAT())
            currentSegment.append(muxer.generatePMT())
        }
        
        let videoPackets = muxer.muxVideo(data: frame.data, pts: frame.pts,
                                           dts: frame.dts, isKeyFrame: frame.isKeyFrame)
        currentSegment.append(videoPackets)
        lastVideoPTS = frame.pts
    }
    
    /// Accepts an encoded audio frame and appends it to the current segment.
    ///
    /// Audio arriving before the first video keyframe (i.e., before PAT/PMT have been written)
    /// is discarded to keep the segment structure valid — the player must see tables first.
    func addAudioFrame(_ frame: EncodedAudioFrame) {
        guard isActive else { return }
        
        // Discard audio arriving before the first video keyframe opens a segment
        guard !currentSegment.isEmpty else { return }
        
        // Wrap the raw AAC frame in a 7-byte ADTS header so decoders can parse it
        var adtsFrame = adtsHeader(frameLength: frame.data.count,
                                   sampleRate: sampleRate, channels: audioChannels)
        adtsFrame.append(frame.data)
        
        let audioPackets = muxer.muxAudio(data: adtsFrame, pts: frame.pts)
        currentSegment.append(audioPackets)
    }
    
    /// Flushes any buffered data as a final segment and stops accepting new frames.
    func finalize() {
        guard isActive else { return }
        isActive = false
        
        if !currentSegment.isEmpty {
            let duration = Double(lastVideoPTS - segmentStartPTS) / 90000.0
            emitSegment(duration: max(duration, 0), isFinal: true)
        }
        LOG("TSSegmenter finalized", level: .debug)
    }
    
    // MARK: - Private
    
    /// Emits the accumulated bytes as a Fragment and resets state for the next segment.
    private func emitSegment(duration: Double, isFinal: Bool) {
        sequenceNumber += 1
        let type: Fragment.SegmentType = isFinal ? .finalization : .separable
        let fragment = Fragment(sequence: sequenceNumber, segment: currentSegment,
                                duration: duration, type: type)
        LOG("Produced TS \(fragment)", level: .debug)
        onSegment?(fragment)
        
        // Reset muxer continuity counters and segment buffer for next segment
        currentSegment = Data()
        muxer.reset()
    }
}
