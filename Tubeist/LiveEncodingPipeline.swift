import AVFoundation

@PipelineActor
final class LiveEncodingPipeline {
    private var videoEncoder: HEVCVideoEncoder?
    private var audioEncoder: AACAudioEncoder?
    private var recording: RecordingAssetWriter?
    private var streams = false
    private var basePTS: CMTime?
    private var startupAudio: [CMSampleBuffer] = []
    private var assembler = EncodedSegmentAssembler()
    private var muxer = MPEGTransportStreamMuxer()
    private var sequence = 0
    private var nextBoundary = 0.0
    private(set) var isActive = false
    var isRecording: Bool { recording != nil }

    func start(preset: Preset, stream: Bool, recording: RecordingAssetWriter?) throws {
        guard !isActive else { throw ContentPackagingError.alreadyEncoding }
        videoEncoder = try HEVCVideoEncoder(width: preset.width, height: preset.height, frameRate: preset.frameRate,
                                             bitrate: preset.videoBitrate, keyframeInterval: preset.keyframeInterval)
        audioEncoder = AACAudioEncoder(channels: preset.audioChannels, bitratePerChannel: preset.audioBitrate,
                                        sampleRate: AUDIO_SAMPLE_RATE)
        self.recording = recording
        streams = stream
        basePTS = nil
        startupAudio.removeAll()
        assembler = EncodedSegmentAssembler(segmentDuration: FRAGMENT_DURATION)
        muxer.reset()
        sequence = 0
        nextBoundary = 0
        isActive = true
    }

    func appendVideo(_ sample: CMSampleBuffer) async throws {
        guard isActive, let videoEncoder, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sample)
        if basePTS == nil {
            basePTS = sourcePTS
            for audio in startupAudio { try encodeAudio(audio, basePTS: sourcePTS) }
            startupAudio.removeAll()
        }
        guard let basePTS else { return }
        let pts = CMTimeSubtract(sourcePTS, basePTS)
        let boundary = pts.seconds >= nextBoundary - videoEncoder.frameDuration.seconds * 0.5
        if boundary {
            if streams, let target = await EncodedOutputRouter.shared.recommendedVideoBitrate(), target != videoEncoder.bitrate {
                try videoEncoder.setBitrate(target)
                LOG("Adjusted HEVC target to \(target) bps at a segment boundary", level: .info)
            }
            nextBoundary = (floor((pts.seconds + videoEncoder.frameDuration.seconds * 0.5) / FRAGMENT_DURATION) + 1) * FRAGMENT_DURATION
        }
        try videoEncoder.encode(pixels, presentationTime: pts, forceKeyframe: boundary)
        try consumeVideo(videoEncoder.takeOutput())
        try await publishReadySegments()
    }

    func appendAudio(_ sample: CMSampleBuffer) async throws {
        guard isActive else { return }
        guard let basePTS else {
            startupAudio.append(sample)
            while let first = startupAudio.first,
                  CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), CMSampleBufferGetPresentationTimeStamp(first)).seconds > 1 {
                startupAudio.removeFirst()
            }
            return
        }
        try encodeAudio(sample, basePTS: basePTS)
        if let videoEncoder { try consumeVideo(videoEncoder.takeOutput()) }
        try await publishReadySegments()
    }

    private func encodeAudio(_ sample: CMSampleBuffer, basePTS: CMTime) throws {
        guard let audioEncoder else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        var input = sample
        if pts < basePTS {
            guard let format = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return }
            let skip = Int(ceil(CMTimeSubtract(basePTS, pts).seconds * asbd.pointee.mSampleRate))
            let count = CMSampleBufferGetNumSamples(sample)
            if skip >= count { return }
            var trimmed: CMSampleBuffer?
            try checkMediaStatus(CMSampleBufferCopySampleBufferForRange(allocator: nil, sampleBuffer: sample,
                sampleRange: CFRange(location: skip, length: count - skip), sampleBufferOut: &trimmed), "Trimming startup audio")
            guard let trimmed else { throw MediaEncodingError.invalid("Could not align startup audio") }
            input = trimmed
        }
        try consumeAudio(audioEncoder.encode(input, basePTS: basePTS))
    }

    private func consumeVideo(_ samples: [CMSampleBuffer]) throws {
        for sample in samples {
            try recording?.append(sample, kind: .video)
            if streams {
                guard let format = CMSampleBufferGetFormatDescription(sample) else {
                    throw MediaEncodingError.invalid("HEVC output has no format")
                }
                let config = try EncodedSampleAdapter.hevcConfiguration(format)
                if let previous = assembler.hevc, previous != config {
                    throw MediaEncodingError.invalid("HEVC configuration changed during streaming")
                }
                assembler.hevc = config
                try assembler.append(EncodedSampleAdapter.sample(sample, kind: .video,
                                                                  fallbackDuration: videoEncoder?.frameDuration))
            }
        }
    }

    private func consumeAudio(_ samples: [CMSampleBuffer]) throws {
        assembler.aac = audioEncoder?.configuration
        for sample in samples {
            try recording?.append(sample, kind: .audio)
            if streams { try assembler.append(EncodedSampleAdapter.sample(sample, kind: .audio)) }
        }
    }

    private func publishReadySegments(finishing: Bool = false) async throws {
        guard streams else { return }
        // Allocate sequence numbers before suspension; concurrent audio/video
        // intake may publish later segments while this call awaits the router.
        let fragments = try assembler.takeReadySegments(finishing: finishing).map { segment in
            let transport = try muxer.mux(segment)
            guard transport.duration <= 5 else {
                throw MediaEncodingError.invalid("Encoded segment exceeds YouTube's duration limit")
            }
            defer { sequence += 1 }
            return Fragment(sequence: sequence, segment: transport.data, duration: transport.duration,
                            container: .mpegTransportStream)
        }
        for fragment in fragments { await EncodedOutputRouter.shared.route(fragment) }
    }

    func finish(deadline: ContinuousClock.Instant) async throws {
        guard isActive else { return }
        defer {
            videoEncoder = nil
            audioEncoder = nil
            recording = nil
            startupAudio.removeAll()
            isActive = false
        }
        do {
            guard basePTS != nil else { throw ContentPackagingError.videoNeverStarted }
            if let videoEncoder { try consumeVideo(videoEncoder.finish()) }
            if let audioEncoder { try consumeAudio(audioEncoder.finish()) }
            guard ContinuousClock().now < deadline else {
                throw MediaEncodingError.invalid("Media encoding exceeded its shutdown deadline")
            }
            try await publishReadySegments(finishing: true)
            try await recording?.finish(deadline: deadline)
        } catch {
            recording?.cancel()
            throw error
        }
    }
}
