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
    private var preset: Preset?
    private var repair: VideoCaptureRepair?
    private var lastPixels: CVPixelBuffer?
    private var lastRealVideoPTS: CMTime?
    private var lastRealAudioEndPTS: CMTime?
    private var liveness = CaptureLiveness(startedAt: 0)
    private var watchdog: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var timelineStartedAt: TimeInterval?
    private var recovering = false
    private var recoveryStartedAt: TimeInterval?
    private var candidateVideo: CMSampleBuffer?
    private var candidateAudio: CMSampleBuffer?
    private var recoveryAudio: [CMSampleBuffer] = []
    private var candidateVideoAt = 0.0
    private var candidateAudioAt = 0.0
    private var candidateVideoCount = 0
    private var candidateAudioCount = 0
    private var lastOutputEnd = 0.0
    private var pendingDiscontinuity = false
    private var failed = false
    private var finalizing = false
    private let now: @Sendable () -> TimeInterval
    private let automaticWatchdog: Bool
    private let publish: @Sendable (Fragment) async -> Void
    private let reportFailure: @Sendable (any Error) async -> Void
    private(set) var isActive = false
    var isRecording: Bool { recording != nil }
    var captureState: CaptureLiveness.State? {
        guard isActive, !finalizing else { return nil }
        return failed ? .failed : recovering ? .recovering : liveness.state(at: now())
    }

    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         automaticWatchdog: Bool = true,
         publish: @escaping @Sendable (Fragment) async -> Void = { EncodedOutputRouter.shared.route($0) },
         reportFailure: @escaping @Sendable (any Error) async -> Void = { await Streamer.shared.handleRuntimeFailure($0) }) {
        self.now = now
        self.automaticWatchdog = automaticWatchdog
        self.publish = publish
        self.reportFailure = reportFailure
    }

    func start(preset: Preset, stream: Bool, recording: RecordingAssetWriter?) throws {
        guard !isActive else { throw ContentPackagingError.alreadyEncoding }
        self.preset = preset
        generation &+= 1
        lifecycleGeneration &+= 1
        timelineStartedAt = nil
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
        repair = VideoCaptureRepair(frameDuration: videoEncoder!.frameDuration)
        lastPixels = nil
        lastRealVideoPTS = nil
        lastRealAudioEndPTS = nil
        liveness = CaptureLiveness(startedAt: now())
        recovering = false
        recoveryStartedAt = nil
        clearCandidates()
        lastOutputEnd = 0
        pendingDiscontinuity = false
        failed = false
        finalizing = false
        isActive = true
        if automaticWatchdog {
            let activeGeneration = lifecycleGeneration
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self, self.lifecycleGeneration == activeGeneration, self.isActive else { return }
                    do { try await self.checkCapture() }
                    catch {
                        self.failed = true
                        await self.reportFailure(error)
                        return
                    }
                }
            }
        }
    }

    func appendVideo(_ sample: CMSampleBuffer) async throws {
        guard isActive, !failed, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sample)
        guard sourcePTS.isNumeric else { throw CaptureContinuityError.invalidTiming }
        if recovering { try await receiveRecovery(sample, video: true); return }
        if basePTS == nil {
            basePTS = sourcePTS
            timelineStartedAt = now()
            for audio in startupAudio { try encodeAudio(audio, basePTS: sourcePTS) }
            startupAudio.removeAll()
        }
        guard let basePTS else { return }
        let pts = CMTimeSubtract(sourcePTS, basePTS)
        if let videoEncoder, pts.seconds >= nextBoundary - videoEncoder.frameDuration.seconds * 0.5 {
            let activeGeneration = generation
            if streams, let target = await EncodedOutputRouter.shared.recommendedVideoBitrate(), target != videoEncoder.bitrate {
                guard generation == activeGeneration, isActive, !recovering else { return }
                try videoEncoder.setBitrate(target)
                LOG("Adjusted HEVC target to \(target) bps at a segment boundary", level: .info)
            }
            guard generation == activeGeneration, isActive, !recovering else { return }
        }
        do {
            guard let missing = try repair?.missingFrames(before: pts) else { return }
            // A busy encoder/renderer can skip capture timestamps even while
            // fresh frames keep arriving. Re-encoding every skipped frame in
            // that case creates more work and a growing catch-up loop. Keep
            // the real timestamps; only conceal an actual delivery pause.
            if let lastPixels, let arrival = liveness.videoAt,
               now() - arrival >= CaptureLiveness.arrivalGrace {
                try concealVideo(lastPixels, times: missing)
            }
        } catch CaptureContinuityError.discontinuity {
            try await beginRecovery()
            try await receiveRecovery(sample, video: true)
            return
        }
        try submitVideo(pixels, at: pts)
        lastPixels = pixels
        lastRealVideoPTS = pts
        liveness.receivedVideo(at: now())
        try await publishReadySegments()
    }

    private func submitVideo(_ pixels: CVPixelBuffer, at pts: CMTime) throws {
        guard let videoEncoder else { return }
        let boundary = pts.seconds >= nextBoundary - videoEncoder.frameDuration.seconds * 0.5
        if boundary { nextBoundary = pts.seconds + FRAGMENT_DURATION }
        try videoEncoder.encode(pixels, presentationTime: pts, forceKeyframe: boundary)
        repair?.accepted(pts)
        try consumeVideo(videoEncoder.takeOutput())
    }

    private func concealVideo(_ pixels: CVPixelBuffer, times: [CMTime]) throws {
        guard let videoEncoder else { return }
        let started = now()
        // A concealment batch must not monopolize the capture actor and block
        // microphone delivery. One encoder submission can itself block, so
        // check the elapsed budget before issuing each additional duplicate.
        for time in times {
            guard now() - started < videoEncoder.frameDuration.seconds else { break }
            try submitVideo(pixels, at: time)
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) async throws {
        guard isActive, !failed else { return }
        guard CMSampleBufferGetPresentationTimeStamp(sample).isNumeric else { throw CaptureContinuityError.invalidTiming }
        if recovering { try await receiveRecovery(sample, video: false); return }
        guard let basePTS else {
            startupAudio.append(try BufferedAudioSample.copy(sample))
            while let first = startupAudio.first,
                  startupAudio.count > 64 || CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), CMSampleBufferGetPresentationTimeStamp(first)).seconds > 1 {
                startupAudio.removeFirst()
            }
            return
        }
        do { try encodeAudio(sample, basePTS: basePTS) }
        catch CaptureContinuityError.discontinuity {
            try await beginRecovery()
            try await receiveRecovery(sample, video: false)
            return
        }
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
            let count = CMSampleBufferGetNumSamples(sample)
            let missing = CMTimeSubtract(basePTS, pts).seconds * asbd.pointee.mSampleRate
            guard missing.isFinite, missing < Double(count) else { return }
            let skip = Int(ceil(missing))
            if skip >= count { return }
            // Range-copy requires sample-size metadata and does not support
            // planar PCM. Copy the actual channel data with an exact frame
            // offset, which also works for our independently owned history.
            input = try BufferedAudioSample.copy(sample, skippingFrames: skip)
        }
        try consumeAudio(audioEncoder.encode(input, basePTS: basePTS))
        if audioEncoder.acceptedInput {
            lastRealAudioEndPTS = audioEncoder.inputEndPTS
            liveness.receivedAudio(at: now())
        }
    }

    private func consumeVideo(_ samples: [CMSampleBuffer]) throws {
        for sample in samples {
            trackOutputEnd(sample)
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
            trackOutputEnd(sample)
            try recording?.append(sample, kind: .audio)
            if streams { try assembler.append(EncodedSampleAdapter.sample(sample, kind: .audio)) }
        }
    }

    private func trackOutputEnd(_ sample: CMSampleBuffer) {
        let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sample), CMSampleBufferGetDuration(sample))
        if end.isNumeric { lastOutputEnd = max(lastOutputEnd, end.seconds) }
    }

    /// Called by an independent timer, and directly by deterministic fault tests.
    func checkCapture() async throws {
        guard isActive, !failed, !finalizing else { return }
        let time = now()
        if recovering {
            if time - (recoveryStartedAt ?? time) >= 30 {
                let separation: String
                if let video = candidateVideo, let audio = candidateAudio {
                    separation = String(format: "%.3f", CMTimeSubtract(
                        CMSampleBufferGetPresentationTimeStamp(audio),
                        CMSampleBufferGetPresentationTimeStamp(video)
                    ).seconds)
                } else { separation = "unavailable" }
                LOG("Capture recovery timed out: \(candidateVideoCount) video and \(candidateAudioCount) audio candidates; latest audio minus video timestamp: \(separation)s", level: .error)
                throw CaptureContinuityError.stalled
            }
            return
        }
        switch liveness.state(at: time) {
        case .failed: throw CaptureContinuityError.stalled
        case .recovering: try await beginRecovery()
        case .starting, .healthy: break
        case .concealing:
            if let lastPixels, let pts = lastRealVideoPTS, let arrival = liveness.videoAt,
               time - arrival >= CaptureLiveness.arrivalGrace, let repair {
                let until = CMTimeAdd(pts, CMTime(seconds: time - arrival - CaptureLiveness.arrivalGrace, preferredTimescale: 90_000))
                if let missing = try repair.missingFrames(before: until) {
                    try concealVideo(lastPixels, times: missing)
                }
            }
            if let end = lastRealAudioEndPTS, let arrival = liveness.audioAt,
               time - arrival >= CaptureLiveness.arrivalGrace, let audioEncoder {
                let until = CMTimeAdd(end, CMTime(seconds: time - arrival - CaptureLiveness.arrivalGrace, preferredTimescale: 90_000))
                try consumeAudio(audioEncoder.fillSilence(until: until))
            }
            if let videoEncoder { try consumeVideo(videoEncoder.takeOutput()) }
            try await publishReadySegments()
        }
    }

    private func beginRecovery() async throws {
        guard !finalizing else { throw CaptureContinuityError.discontinuity }
        guard !recovering else { return }
        recovering = true
        generation &+= 1
        // Keep the watchdog alive across epochs; its lifecycle belongs to start/
        // finish, while generation invalidates suspended input/publish calls.
        recoveryStartedAt = now()
        clearCandidates()
        if let videoEncoder { try consumeVideo(videoEncoder.finish()) }
        if let audioEncoder { try consumeAudio(audioEncoder.finish()) }
        let fragments = try makeReadyFragments()
        // Any unmatched partial GOP stays in the recording, but is unsuitable
        // for an independently decodable live segment.
        assembler = EncodedSegmentAssembler(segmentDuration: FRAGMENT_DURATION)
        videoEncoder = nil
        audioEncoder = nil
        lastPixels = nil
        lastRealVideoPTS = nil
        lastRealAudioEndPTS = nil
        startupAudio.removeAll()
        pendingDiscontinuity = true
        LOG("Capture stalled; waiting for fresh camera and microphone samples", level: .warning)
        for fragment in fragments { await publish(fragment) }
    }

    private func clearCandidates() {
        candidateVideo = nil
        candidateAudio = nil
        recoveryAudio.removeAll()
        candidateVideoCount = 0
        candidateAudioCount = 0
    }

    private func receiveRecovery(_ sample: CMSampleBuffer, video: Bool) async throws {
        guard recovering, !finalizing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let previous = video ? candidateVideo : candidateAudio
        let previousAt = video ? candidateVideoAt : candidateAudioAt
        if let previous, now() - previousAt < 0.5 {
            if pts <= CMSampleBufferGetPresentationTimeStamp(previous) { return }
        } else if video { candidateVideoCount = 0 }
        else {
            candidateAudioCount = 0
            recoveryAudio.removeAll()
        }
        if video {
            candidateVideo = sample
            candidateVideoAt = now()
            candidateVideoCount += 1
        } else {
            let ownedSample = try BufferedAudioSample.copy(sample)
            candidateAudio = ownedSample
            candidateAudioAt = now()
            candidateAudioCount += 1
            recoveryAudio.append(ownedSample)
            // Stabilization can deliver video well behind the microphone.
            // Retain a bounded PCM history only while recovering, so a fresh
            // video frame can be paired with audio from the same capture time.
            while let first = recoveryAudio.first,
                  recoveryAudio.count > 512 || CMTimeSubtract(pts, CMSampleBufferGetPresentationTimeStamp(first)).seconds > 5 {
                recoveryAudio.removeFirst()
            }
        }
        guard candidateVideoCount >= 2, candidateAudioCount >= 2,
              let videoSample = candidateVideo, let audioSample = candidateAudio, let preset,
              now() - min(candidateVideoAt, candidateAudioAt) < 0.5 else { return }
        let videoPTS = CMSampleBufferGetPresentationTimeStamp(videoSample)
        let audioPTS = CMSampleBufferGetPresentationTimeStamp(audioSample)
        guard let matchingAudio = recoveryAudio.firstIndex(where: { sample in
            let start = CMSampleBufferGetPresentationTimeStamp(sample)
            let end = CMTimeAdd(start, CMSampleBufferGetDuration(sample))
            return start <= videoPTS && end.isNumeric && end > videoPTS
        }) else { return }
        let alignedAudio = Array(recoveryAudio[matchingAudio...])
        let audioLead = CMTimeSubtract(videoPTS, CMSampleBufferGetPresentationTimeStamp(alignedAudio[0])).seconds
        let deliveryLag = String(format: "%.3f", CMTimeSubtract(audioPTS, videoPTS).seconds)
        // Both tracks move to the same new epoch. Keep enough decoding lead for
        // HEVC B frames and AAC priming, including after a backward clock reset.
        let resumeTime = max(now() - (timelineStartedAt ?? liveness.startedAt), lastOutputEnd + 0.5 + audioLead)
        let recoveryBasePTS = CMTimeSubtract(videoPTS, CMTime(seconds: resumeTime, preferredTimescale: 90_000))
        basePTS = recoveryBasePTS
        videoEncoder = try HEVCVideoEncoder(width: preset.width, height: preset.height, frameRate: preset.frameRate,
            bitrate: preset.videoBitrate, keyframeInterval: preset.keyframeInterval)
        audioEncoder = AACAudioEncoder(channels: preset.audioChannels, bitratePerChannel: preset.audioBitrate,
                                       sampleRate: AUDIO_SAMPLE_RATE)
        repair = VideoCaptureRepair(frameDuration: videoEncoder!.frameDuration)
        // The new encoder timestamps already continue the shared timeline.
        // Preserve the transport's original timestamp shift and packet counters.
        nextBoundary = resumeTime
        recovering = false
        recoveryStartedAt = nil
        liveness.receivedVideo(at: now())
        liveness.receivedAudio(at: now())
        clearCandidates()
        // Drain the aligned audio before the first await. Otherwise a new live
        // microphone callback could overtake it and discard it as late input.
        for audio in alignedAudio { try encodeAudio(audio, basePTS: recoveryBasePTS) }
        try await appendVideo(videoSample)
        LOG("Camera and microphone recovered on a shared timeline; video delivery lag \(deliveryLag)s", level: .info)
    }

    private func publishReadySegments(finishing: Bool = false) async throws {
        let session = lifecycleGeneration
        let fragments = try makeReadyFragments(finishing: finishing)
        for fragment in fragments {
            guard session == lifecycleGeneration else { return }
            await publish(fragment)
        }
    }

    private func makeReadyFragments(finishing: Bool = false) throws -> [Fragment] {
        guard streams else { return [] }
        // Allocate sequence numbers before suspension; concurrent audio/video
        // intake may publish later segments while this call awaits the router.
        return try assembler.takeReadySegments(finishing: finishing).map { segment in
            let transport = try muxer.mux(segment)
            guard transport.duration <= 5 else {
                throw MediaEncodingError.invalid("Encoded segment exceeds YouTube's duration limit")
            }
            defer { sequence += 1 }
            let discontinuity = pendingDiscontinuity
            pendingDiscontinuity = false
            return Fragment(sequence: sequence, segment: transport.data, duration: transport.duration, discontinuity: discontinuity,
                            container: .mpegTransportStream)
        }
    }

    func beginFinalization() {
        // Stop deliberately freezes audio while stabilized video catches up.
        // Neither concealment nor recovery may extend that captured tail.
        finalizing = true
        watchdog?.cancel()
        watchdog = nil
    }

    func finish(deadline: ContinuousClock.Instant) async throws {
        guard isActive else { return }
        beginFinalization()
        generation &+= 1
        lifecycleGeneration &+= 1
        failed = true
        defer {
            videoEncoder = nil
            audioEncoder = nil
            recording = nil
            startupAudio.removeAll()
            lastPixels = nil
            clearCandidates()
            isActive = false
        }
        do {
            guard basePTS != nil else { throw ContentPackagingError.videoNeverStarted }
            if let videoEncoder { try consumeVideo(videoEncoder.finish()) }
            if let audioEncoder { try consumeAudio(audioEncoder.finish()) }
            guard ContinuousClock().now < deadline else {
                throw MediaEncodingError.invalid("Media encoding exceeded its shutdown deadline")
            }
            if !recovering { try await publishReadySegments(finishing: true) }
            try await recording?.finish(deadline: deadline)
        } catch {
            recording?.cancel()
            throw error
        }
    }
}
