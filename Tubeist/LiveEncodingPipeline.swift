import AVFoundation

@PipelineActor
final class LiveEncodingPipeline {
    private var videoEncoder: HEVCVideoEncoder?
    private var encoderSelection = HEVCEncoderSelection()
    private var audioEncoder: AACAudioEncoder?
    private var recording: RecordingAssetWriter?
    private var recordsLocally = false
    private var recordingSalvage: Task<Void, Never>?
    /// Set when the local recording stopped during the session; Stop reports it.
    private(set) var recordingFailure: String?
    private var videoDrops = 0
    private var encoderDropsSeen = 0
    private var encoderFailuresSeen = 0
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
    private var liveness: CaptureLiveness?
    private var watchdog: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0
    private var timelineStartedAt: TimeInterval?
    private var recoveryStartedAt: TimeInterval?
    private var recovering: Bool { recoveryStartedAt != nil }
    private var candidateVideo: CMSampleBuffer?
    private var candidateVideoHeldSince = 0.0
    private var latestRecoveryVideoPTS: CMTime?
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
    private let outputFeedback: @Sendable () -> StreamEncoderFeedback
    private let reportFailure: @Sendable (any Error) async -> Void
    private(set) var isActive = false
    var isRecording: Bool { recordsLocally }
    var captureState: CaptureLiveness.State? {
        guard isActive, !finalizing else { return nil }
        if failed { return .failed }
        if recovering { return .recovering }
        return liveness?.state(at: now()) ?? .starting
    }

    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         automaticWatchdog: Bool = true,
         publish: @escaping @Sendable (Fragment) async -> Void = { EncodedOutputRouter.shared.route($0) },
         outputFeedback: @escaping @Sendable () -> StreamEncoderFeedback = { YouTubeHLSStreamSink.shared.latestEncoderFeedback },
         reportFailure: @escaping @Sendable (any Error) async -> Void = { await Streamer.shared.handleRuntimeFailure($0) }) {
        self.now = now
        self.automaticWatchdog = automaticWatchdog
        self.publish = publish
        self.outputFeedback = outputFeedback
        self.reportFailure = reportFailure
    }

    func start(preset: Preset, stream: Bool, recording: RecordingAssetWriter?,
               recordsLocally: Bool? = nil,
               allows422: Bool = true, serviceName: String = MPEGTransportStreamMuxer.defaultServiceName,
               waitForCapture: Bool = false) throws {
        guard !isActive else { throw ContentPackagingError.alreadyEncoding }
        try HEVCEncoderConfiguration.validate(width: preset.width, height: preset.height,
            frameRate: preset.frameRate, bitrate: preset.videoBitrate, keyframeInterval: preset.keyframeInterval)
        self.preset = preset
        lifecycleGeneration &+= 1
        timelineStartedAt = nil
        // Defer hardware setup until the first actual camera buffer, so capture
        // format differences across cameras/OS versions cannot select 4:2:2 for
        // a 4:2:0 source. Audio retains its bounded startup history meanwhile.
        videoEncoder = nil
        encoderSelection = HEVCEncoderSelection(allows422: allows422)
        audioEncoder = AACAudioEncoder(channels: preset.audioChannels, bitratePerChannel: preset.audioBitrate,
                                        sampleRate: AUDIO_SAMPLE_RATE)
        self.recording = recording
        self.recordsLocally = recordsLocally ?? (recording != nil)
        recordingSalvage = nil
        recordingFailure = nil
        videoDrops = 0
        streams = stream
        basePTS = nil
        startupAudio.removeAll()
        assembler = EncodedSegmentAssembler(segmentDuration: FRAGMENT_DURATION)
        muxer = MPEGTransportStreamMuxer(serviceName: serviceName)
        sequence = 0
        nextBoundary = 0
        repair = nil
        lastPixels = nil
        lastRealVideoPTS = nil
        lastRealAudioEndPTS = nil
        liveness = nil
        recoveryStartedAt = nil
        clearCandidates()
        lastOutputEnd = 0
        pendingDiscontinuity = false
        failed = false
        finalizing = false
        isActive = true
        if !waitForCapture { beginCaptureMonitoring() }
    }

    func beginCaptureMonitoring(reportFailure: (@Sendable (any Error) async -> Void)? = nil) {
        guard isActive, !failed, !finalizing, liveness == nil else { return }
        liveness = CaptureLiveness(startedAt: now())
        if automaticWatchdog {
            let activeGeneration = lifecycleGeneration
            let report = reportFailure ?? self.reportFailure
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self, self.lifecycleGeneration == activeGeneration, self.isActive else { return }
                    do { try await self.checkCapture() }
                    catch {
                        guard self.lifecycleGeneration == activeGeneration, self.isActive,
                              !self.finalizing, !Task.isCancelled else { return }
                        self.failed = true
                        await report(error)
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
        if recovering {
            if try receiveRecovery(sample, video: true) { try await publishReadySegments() }
            return
        }
        if basePTS == nil {
            try prepareVideoEncoder(for: pixels)
            basePTS = sourcePTS
            timelineStartedAt = now()
            for audio in startupAudio { try encodeAudio(audio, basePTS: sourcePTS) }
            startupAudio.removeAll()
        }
        guard let basePTS else { return }
        let pts = CMTimeSubtract(sourcePTS, basePTS)
        do {
            guard let missing = try repair?.missingFrames(before: pts) else { return }
            // A busy encoder/renderer can skip capture timestamps even while
            // fresh frames keep arriving. Re-encoding every skipped frame in
            // that case creates more work and a growing catch-up loop. Keep
            // the real timestamps; only conceal an actual delivery pause.
            if let lastPixels, let arrival = liveness?.videoAt,
               now() - arrival >= CaptureLiveness.arrivalGrace {
                try concealVideo(lastPixels, times: missing)
            }
        } catch CaptureContinuityError.discontinuity {
            let fragments = try beginRecovery(reason: "video timestamp gap")
            _ = try receiveRecovery(sample, video: true)
            await publishFragments(fragments)
            return
        }
        try submitRealVideo(pixels, at: pts)
        try await publishReadySegments()
    }

    private func submitRealVideo(_ pixels: CVPixelBuffer, at pts: CMTime) throws {
        if let videoEncoder, pts.seconds >= nextBoundary - videoEncoder.frameDuration.seconds * 0.5 {
            let feedback = streams ? outputFeedback() : StreamEncoderFeedback()
            if feedback.uploadsStopped { try stopStreaming() }
            // A recording that outlives its stream returns to the selected bitrate.
            let target = streams ? feedback.videoBitrate : preset?.videoBitrate
            if let target, target != videoEncoder.bitrate {
                try videoEncoder.setBitrate(target)
                if streams { LOG("Adjusted HEVC target to \(target) bps at a segment boundary", level: .info) }
            }
        }
        try submitVideo(pixels, at: pts)
        lastPixels = pixels
        lastRealVideoPTS = pts
        liveness?.receivedVideo(at: now())
    }

    private func prepareVideoEncoder(for pixels: CVPixelBuffer) throws {
        guard let preset else { throw MediaEncodingError.invalid("Missing HEVC preset") }
        let firstSetup = encoderSelection.chroma == nil
        videoEncoder = try encoderSelection.makeEncoder(sourcePixelFormat: CVPixelBufferGetPixelFormatType(pixels)) { chroma in
            try HEVCVideoEncoder(width: preset.width, height: preset.height, frameRate: preset.frameRate,
                bitrate: preset.videoBitrate, keyframeInterval: preset.keyframeInterval, chroma: chroma)
        }
        repair = VideoCaptureRepair(frameDuration: videoEncoder!.frameDuration)
        encoderDropsSeen = 0
        encoderFailuresSeen = 0
        if firstSetup, let chroma = encoderSelection.chroma {
            LOG("HEVC hardware encoding: 10-bit \(chroma.rawValue) HLG", level: .info)
            if let reason = encoderSelection.fallbackReason {
                LOG("HEVC 4:2:2 not used: \(reason)", level: .info)
            }
        }
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
        if recovering {
            if try receiveRecovery(sample, video: false) { try await publishReadySegments() }
            return
        }
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
            let fragments = try beginRecovery(reason: "audio timestamp gap")
            _ = try receiveRecovery(sample, video: false)
            await publishFragments(fragments)
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
        let previousFormat = audioEncoder.inputFormat
        try consumeAudio(audioEncoder.encode(input, basePTS: basePTS))
        if let previousFormat, let format = audioEncoder.inputFormat, previousFormat != format {
            LOG("Microphone format changed from \(Self.describe(previousFormat)) to \(Self.describe(format)); AAC output continues unchanged", level: .info)
        }
        if audioEncoder.acceptedInput {
            lastRealAudioEndPTS = audioEncoder.inputEndPTS
            liveness?.receivedAudio(at: now())
        }
    }

    private func consumeVideo(_ samples: [CMSampleBuffer]) throws {
        reportVideoDrops()
        for sample in samples {
            trackOutputEnd(sample)
            try record(sample, kind: .video)
            if streams {
                guard let format = CMSampleBufferGetFormatDescription(sample) else {
                    throw MediaEncodingError.invalid("HEVC output has no format")
                }
                let config = try EncodedSampleAdapter.hevcConfiguration(format)
                // Only parameter-set changes break the stream; carry the
                // latest SEI (HDR metadata) forward to the next IRAP.
                if let previous = assembler.hevc, !previous.hasSameParameterSets(as: config) {
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
            try record(sample, kind: .audio)
            if streams { try assembler.append(EncodedSampleAdapter.sample(sample, kind: .audio)) }
        }
    }

    /// The recording and the live stream are independent outputs: a writer or
    /// storage failure ends only the recording. Fragments it already produced
    /// remain in the file, and Stop reports the failure as the recording's.
    private func record(_ sample: CMSampleBuffer, kind: ISOBMFFTrackKind) throws {
        guard let recording else { return }
        do { try recording.append(sample, kind: kind) }
        catch {
            self.recording = nil
            if recordsLocally { recordingFailure = error.localizedDescription }
            HighlightRecorder.shared.stopAfterFailure()
            recordingSalvage = Task { @PipelineActor in
                await recording.finishAfterFailure(deadline: ContinuousClock().now.advanced(by: .seconds(10)))
            }
            // Without a live stream, the session has no output left.
            guard streams else { throw error }
            if recordsLocally {
                LOG("Local recording stopped: \(error.localizedDescription). The live stream continues.", level: .error)
            } else {
                LOG("Highlight buffering stopped: \(error.localizedDescription). The live stream continues.", level: .warning)
            }
        }
    }

    /// YouTube permanently stopped accepting this session's uploads, and
    /// Streamer has reported why. Stop packaging segments that can never be
    /// delivered; a simultaneous recording continues at the selected bitrate.
    private func stopStreaming() throws {
        streams = false
        assembler = EncodedSegmentAssembler(segmentDuration: FRAGMENT_DURATION)
        LOG("Stopped packaging live segments because YouTube no longer accepts this stream", level: .info)
        if recordsLocally, recording == nil {
            throw MediaEncodingError.invalid("YouTube stopped accepting the stream after the local recording had stopped")
        }
    }

    /// VideoToolbox may drop a frame under real-time load or thermal pressure.
    /// The encoder already retired its timing; report the first drop and every 30th.
    private func reportVideoDrops() {
        if let failed = videoEncoder?.failedFrames, failed > encoderFailuresSeen {
            let count = failed - encoderFailuresSeen
            encoderFailuresSeen = failed
            let status = videoEncoder?.lastFailureStatus.map(String.init) ?? "unknown"
            LOG("The HEVC encoder returned an error for \(count) frame\(count == 1 ? "" : "s") (status \(status)); withholding dependent video until a keyframe is confirmed", level: .warning)
        }
        guard let dropped = videoEncoder?.droppedFrames, dropped > encoderDropsSeen else { return }
        let previous = videoDrops
        videoDrops += dropped - encoderDropsSeen
        encoderDropsSeen = dropped
        if previous == 0 || previous / 30 != videoDrops / 30 {
            LOG("The HEVC encoder has dropped \(videoDrops) frame\(videoDrops == 1 ? "" : "s") under real-time load; encoding continues", level: .warning)
        }
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate)) Hz \(format.channelCount == 1 ? "mono" : "\(format.channelCount)-channel")"
    }

    private func trackOutputEnd(_ sample: CMSampleBuffer) {
        let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sample), CMSampleBufferGetDuration(sample))
        if end.isNumeric { lastOutputEnd = max(lastOutputEnd, end.seconds) }
    }

    /// Called by an independent timer, and directly by deterministic fault tests.
    func checkCapture() async throws {
        guard isActive, !failed, !finalizing, let liveness else { return }
        let time = now()
        if let recoveryStartedAt {
            if time - recoveryStartedAt >= 30 {
                let separation: String
                if let videoPTS = latestRecoveryVideoPTS, let audio = candidateAudio {
                    separation = String(format: "%.3f s", CMTimeSubtract(
                        CMSampleBufferGetPresentationTimeStamp(audio), videoPTS
                    ).seconds)
                } else { separation = "unavailable" }
                LOG("Capture recovery timed out: \(candidateVideoCount) video and \(candidateAudioCount) audio candidates; latest audio minus video timestamp: \(separation)", level: .error)
                throw CaptureContinuityError.stalled
            }
            return
        }
        switch liveness.state(at: time) {
        case .recovering, .failed:
            // A delayed watchdog tick must still give capture time to recover.
            let videoAge = time - (liveness.videoAt ?? liveness.startedAt)
            let audioAge = time - (liveness.audioAt ?? liveness.startedAt)
            let reason = String(format: "no usable samples for video %.3fs, audio %.3fs", videoAge, audioAge)
            await publishFragments(try beginRecovery(reason: reason))
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

    private func beginRecovery(reason: String) throws -> [Fragment] {
        guard !finalizing else { throw CaptureContinuityError.discontinuity }
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
        // Start counting once the old encoders have drained and new samples
        // can actually be considered for recovery.
        recoveryStartedAt = now()
        LOG("Capture recovery started (\(reason)); waiting for aligned camera and microphone samples", level: .warning)
        return fragments
    }

    private func clearCandidates() {
        candidateVideo = nil
        latestRecoveryVideoPTS = nil
        candidateAudio = nil
        recoveryAudio.removeAll()
        candidateVideoCount = 0
        candidateAudioCount = 0
    }

    private func receiveRecovery(_ sample: CMSampleBuffer, video: Bool) throws -> Bool {
        guard !finalizing else { return false }
        let time = now()
        let freshness = 0.5
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let previousPTS = video ? latestRecoveryVideoPTS : candidateAudio?.presentationTimeStamp
        let previousAt = video ? candidateVideoAt : candidateAudioAt
        if let previousPTS, time - previousAt < freshness {
            guard pts > previousPTS else { return false }
        } else if video {
            candidateVideoCount = 0
            candidateVideo = nil
        } else {
            candidateAudioCount = 0
            recoveryAudio.removeAll()
        }
        if video {
            // Pin one frame while the audio clock catches up. Replacing it on
            // every callback can keep the target permanently ahead of audio.
            // Release it if audio has passed it or it cannot join live video
            // within the normal timestamp-gap limit.
            let keepHeldFrame = candidateVideo.map { held in
                let heldPTS = held.presentationTimeStamp
                return time - candidateVideoHeldSince < CaptureLiveness.concealmentLimit
                    && CMTimeSubtract(pts, heldPTS).seconds < CaptureLiveness.concealmentLimit
                    && (candidateAudio.map { $0.presentationTimeStamp <= heldPTS } ?? true)
            } ?? false
            if !keepHeldFrame {
                candidateVideo = sample
                candidateVideoHeldSince = time
            }
            latestRecoveryVideoPTS = pts
            candidateVideoAt = time
            candidateVideoCount += 1
        } else {
            let ownedSample = try BufferedAudioSample.copy(sample)
            candidateAudio = ownedSample
            candidateAudioAt = time
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
              let pixels = CMSampleBufferGetImageBuffer(videoSample),
              time - min(candidateVideoAt, candidateAudioAt) < freshness,
              time - candidateVideoHeldSince < CaptureLiveness.concealmentLimit else { return false }
        let videoPTS = CMSampleBufferGetPresentationTimeStamp(videoSample)
        let audioPTS = CMSampleBufferGetPresentationTimeStamp(audioSample)
        guard let matchingAudio = recoveryAudio.firstIndex(where: { sample in
            let start = CMSampleBufferGetPresentationTimeStamp(sample)
            let end = CMTimeAdd(start, CMSampleBufferGetDuration(sample))
            return start <= videoPTS && end.isNumeric && end > videoPTS
        }) else { return false }
        let alignedAudio = Array(recoveryAudio[matchingAudio...])
        let audioLead = CMTimeSubtract(videoPTS, CMSampleBufferGetPresentationTimeStamp(alignedAudio[0])).seconds
        let deliveryLag = String(format: "%.3f", CMTimeSubtract(audioPTS, latestRecoveryVideoPTS ?? videoPTS).seconds)
        // Both tracks move to the same new epoch. Keep enough decoding lead for
        // HEVC B frames and AAC priming, including after a backward clock reset.
        let resumeTime = max(time - (timelineStartedAt ?? liveness?.startedAt ?? time), lastOutputEnd + 0.5 + audioLead)
        let recoveryBasePTS = CMTimeSubtract(videoPTS, CMTime(seconds: resumeTime, preferredTimescale: 90_000))
        basePTS = recoveryBasePTS
        try prepareVideoEncoder(for: pixels)
        audioEncoder = AACAudioEncoder(channels: preset.audioChannels, bitratePerChannel: preset.audioBitrate,
                                       sampleRate: AUDIO_SAMPLE_RATE)
        // The new encoder timestamps already continue the shared timeline.
        // Preserve the transport's original timestamp shift and packet counters.
        nextBoundary = resumeTime
        // The recording pads this gap with silence, however long the outage was.
        recording?.allowRecoveryGap(through: CMTime(seconds: resumeTime, preferredTimescale: 90_000))
        // Commit both tracks before any suspension. New capture or Stop can
        // interleave once the completed fragments are handed off.
        for audio in alignedAudio { try encodeAudio(audio, basePTS: recoveryBasePTS) }
        try submitRealVideo(pixels, at: CMTimeSubtract(videoPTS, recoveryBasePTS))
        recoveryStartedAt = nil
        clearCandidates()
        LOG("Camera and microphone recovered on a shared timeline; video delivery lag \(deliveryLag)s", level: .info)
        return true
    }

    private func publishReadySegments(finishing: Bool = false) async throws {
        await publishFragments(try makeReadyFragments(finishing: finishing))
    }

    private func publishFragments(_ fragments: [Fragment]) async {
        let session = lifecycleGeneration
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
        lifecycleGeneration &+= 1
        failed = true
        defer {
            if videoDrops > 0 {
                LOG("The HEVC encoder dropped \(videoDrops) of this session's frames under real-time load", level: .info)
            }
            videoEncoder = nil
            audioEncoder = nil
            recording = nil
            recordsLocally = false
            recordingSalvage = nil
            startupAudio.removeAll()
            lastPixels = nil
            clearCandidates()
            liveness = nil
            isActive = false
        }
        var packagingFailure: (any Error)?
        do {
            guard basePTS != nil else { throw ContentPackagingError.videoNeverStarted }
            if let videoEncoder { try consumeVideo(videoEncoder.finish()) }
            if let audioEncoder { try consumeAudio(audioEncoder.finish()) }
            guard ContinuousClock().now < deadline else {
                throw MediaEncodingError.invalid("Media encoding exceeded its shutdown deadline")
            }
            if !recovering {
                do { try await publishReadySegments(finishing: true) }
                catch {
                    packagingFailure = error
                    LOG("Final stream segment could not be packaged: \(error.localizedDescription)", level: .error)
                }
            }
            // The recording already has the compressed samples. A transport
            // packaging failure must not cancel its otherwise valid ending.
            await recordingSalvage?.value
            do { try await recording?.finish(deadline: deadline) }
            catch {
                if recordsLocally { throw error }
                recording?.cancel()
                HighlightRecorder.shared.stopAfterFailure()
                LOG("Highlight buffering could not finalize: \(error.localizedDescription)", level: .warning)
            }
        } catch {
            recording?.cancel()
            await recordingSalvage?.value
            throw error
        }
        if let packagingFailure { throw packagingFailure }
    }
}
