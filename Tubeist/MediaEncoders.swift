import AVFoundation
import VideoToolbox

enum MediaEncodingError: LocalizedError {
    case operation(String, OSStatus)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .operation(let name, let status): "\(name) failed (\(status))"
        case .invalid(let message): message
        }
    }
}

func checkMediaStatus(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw MediaEncodingError.operation(operation, status) }
}

/// Long-lived audio history must own its bytes. Retaining capture-owned PCM
/// can exhaust the microphone's buffer pool even when our array is bounded.
enum BufferedAudioSample {
    static func copy(_ source: CMSampleBuffer, skippingFrames: Int = 0) throws -> CMSampleBuffer {
        guard let description = CMSampleBufferGetFormatDescription(source),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM else {
            throw MediaEncodingError.invalid("Buffered microphone audio must be PCM")
        }
        let sourceCount = CMSampleBufferGetNumSamples(source)
        guard skippingFrames >= 0, skippingFrames < sourceCount else {
            throw CaptureContinuityError.invalidTiming
        }
        let count = sourceCount - skippingFrames
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard count > 0, Double(count) <= format.sampleRate,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw CaptureContinuityError.invalidTiming
        }
        pcm.frameLength = AVAudioFrameCount(count)
        try checkMediaStatus(CMSampleBufferCopyPCMDataIntoAudioBufferList(source, at: Int32(skippingFrames),
            frameCount: Int32(count), into: pcm.mutableAudioBufferList), "Copying buffered microphone PCM")
        var timing = CMSampleTimingInfo()
        try checkMediaStatus(CMSampleBufferGetSampleTimingInfo(source, at: 0, timingInfoOut: &timing),
                             "Reading buffered microphone timing")
        if skippingFrames > 0 {
            guard timing.duration.isNumeric, timing.duration > .zero else {
                throw CaptureContinuityError.invalidTiming
            }
            let offset = CMTimeMultiply(timing.duration, multiplier: Int32(skippingFrames))
            timing.presentationTimeStamp = CMTimeAdd(timing.presentationTimeStamp, offset)
            if timing.decodeTimeStamp.isNumeric {
                timing.decodeTimeStamp = CMTimeAdd(timing.decodeTimeStamp, offset)
            }
        }
        var copy: CMSampleBuffer?
        try checkMediaStatus(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: count,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &copy), "Creating buffered microphone sample")
        guard let copy else { throw MediaEncodingError.invalid("Could not create buffered microphone sample") }
        try checkMediaStatus(CMSampleBufferSetDataBufferFromAudioBufferList(copy,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            bufferList: pcm.audioBufferList), "Storing independent microphone bytes")
        try checkMediaStatus(CMSampleBufferSetDataReady(copy), "Marking buffered microphone sample ready")
        return copy
    }
}

/// The callback only stores compressed buffers under a lock. The pipeline
/// drains them in callback order; one unstructured Task per frame could reorder
/// packets and race encoder shutdown.
private final class VideoEncoderOutput: @unchecked Sendable {
    enum Event {
        case encoded(frame: Int, CMSampleBuffer)
        case dropped(frame: Int)
        case failed(frame: Int, OSStatus)
    }

    private let lock = NSLock()
    private var events: [Event] = []

    func receive(status: OSStatus, flags: VTEncodeInfoFlags, frame: Int, sample: CMSampleBuffer?) {
        lock.withLock {
            // One frame's error is not yet the session's: the encoder decides
            // whether recovery can safely continue.
            if status != noErr { events.append(.failed(frame: frame, status)) }
            // Real-time encoding may drop a frame under load or thermal pressure,
            // delivering no sample. Its timing is retired; the stream continues.
            else if flags.contains(.frameDropped) || sample == nil { events.append(.dropped(frame: frame)) }
            else if let sample { events.append(.encoded(frame: frame, sample)) }
        }
    }

    func take() -> [Event] {
        lock.withLock {
            let result = events
            events.removeAll(keepingCapacity: true)
            return result
        }
    }
}

/// An errored picture may still be referenced by output already queued in
/// VideoToolbox. Only an actual closed-GOP keyframe makes that output safe
/// again; requesting a keyframe on a future input is not confirmation.
struct HEVCFrameRecovery {
    let maximumWaitingFrames: Int
    private(set) var requiresKeyframe = false
    private var failures = 0
    private var waitingFrames = 0
    static let maximumFailures = 5

    init(maximumWaitingFrames: Int) {
        self.maximumWaitingFrames = maximumWaitingFrames
    }

    mutating func failed(_ status: OSStatus) throws {
        failures += 1
        guard failures < Self.maximumFailures else {
            throw MediaEncodingError.operation("HEVC encoding", status)
        }
        requiresKeyframe = true
        try discarded()
    }

    mutating func shouldEmit(isKeyframe: Bool) throws -> Bool {
        if requiresKeyframe, !isKeyframe {
            try discarded()
            return false
        }
        requiresKeyframe = false
        failures = 0
        waitingFrames = 0
        return true
    }

    mutating func discarded() throws {
        guard requiresKeyframe else { return }
        waitingFrames += 1
        guard waitingFrames <= maximumWaitingFrames else {
            throw MediaEncodingError.invalid("The HEVC encoder did not return a recovery keyframe")
        }
    }
}

/// Assign decode-order timestamps using the SPS picture-reordering depth.
/// Like FFmpeg's PTS-based DTS reconstruction, use the presentation timeline
/// delayed by the reorder depth, not by the encoder's processing window.
/// Actual submitted PTS preserve timing when capture cadence is irregular.
struct VideoDecodeTimeline {
    let frameDuration: CMTime
    private(set) var reorderFrames: Int?
    private var firstPTS: CMTime?
    private var inputPTS: [CMTime] = []
    private var emitted = 0
    private var pendingOutputs = 0
    private var lastDTS: CMTime?

    init(frameDuration: CMTime) {
        self.frameDuration = frameDuration
    }

    mutating func configure(reorderFrames: Int) throws {
        guard (0...15).contains(reorderFrames),
              self.reorderFrames == nil || self.reorderFrames == reorderFrames else {
            // A new encoder starts a fresh timeline during capture recovery.
            // Do not change the lead halfway through an existing decode timeline.
            throw MediaEncodingError.invalid("HEVC picture reordering changed; encoder restart required")
        }
        self.reorderFrames = reorderFrames
    }

    mutating func submitted(_ pts: CMTime) {
        if firstPTS == nil { firstPTS = pts }
        inputPTS.append(pts)
        pendingOutputs += 1
    }

    mutating func next(presentationTime: CMTime) throws -> CMTime {
        guard let firstPTS, let reorderFrames, !inputPTS.isEmpty, pendingOutputs > 0 else {
            throw MediaEncodingError.invalid("HEVC output has no submitted timing or reordering configuration")
        }
        let dts: CMTime
        if emitted < reorderFrames {
            dts = CMTimeSubtract(firstPTS, CMTimeMultiply(frameDuration,
                multiplier: Int32(reorderFrames - emitted)))
        } else {
            dts = inputPTS[0]
        }
        guard dts.isNumeric, presentationTime.isNumeric, dts <= presentationTime,
              lastDTS.map({ dts > $0 }) ?? true else {
            throw MediaEncodingError.invalid("HEVC decoding timestamps exceed the declared picture-reordering bound")
        }
        if emitted >= reorderFrames { inputPTS.removeFirst() }
        emitted += 1
        pendingOutputs -= 1
        lastDTS = dts
        return dts
    }

    /// A dropped frame is never emitted, so later decode times must follow the
    /// remaining submitted timestamps. A drop reported after its timestamp was
    /// already used as a decode time retires the next unused one instead; the
    /// interim decode times were earlier, never later, than the aligned ones.
    mutating func dropped(presentationTime pts: CMTime) throws {
        guard pendingOutputs > 0, !inputPTS.isEmpty else {
            throw MediaEncodingError.invalid("The HEVC encoder dropped a frame that was not pending")
        }
        if let index = inputPTS.firstIndex(of: pts) { inputPTS.remove(at: index) }
        else { inputPTS.removeFirst() }
        pendingOutputs -= 1
        // If startup pictures were lost, the decode lead belongs to the first
        // surviving picture, not the failed session-opening keyframe.
        if emitted == 0 { firstPTS = inputPTS.first }
    }
}

enum HEVCChromaSampling: String, Sendable {
    case yuv420 = "4:2:0"
    case yuv422 = "4:2:2"

    var profile: CFString {
        self == .yuv422 ? kVTProfileLevel_HEVC_Main42210_AutoLevel : kVTProfileLevel_HEVC_Main10_AutoLevel
    }

    var pixelFormat: OSType {
        self == .yuv422 ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }

    static func preferred(for sourcePixelFormat: OSType) -> Self {
        switch sourcePixelFormat {
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            return .yuv422
        default:
            return .yuv420
        }
    }
}

/// Negotiate once from the delivered camera format and actual hardware setup.
/// Recovery must retain the chosen profile, including a previous 4:2:0 fallback:
/// changing it after samples have reached the MP4 track would invalidate it.
struct HEVCEncoderSelection {
    /// Frozen at Start. YouTube documents a 10-bit 4:2:0 HDR requirement, so a
    /// stream or playback device that rejects 4:2:2 needs a way to opt out.
    let allows422: Bool
    private(set) var chroma: HEVCChromaSampling?
    private(set) var fallbackReason: String?

    init(allows422: Bool = true) {
        self.allows422 = allows422
    }

    mutating func makeEncoder<Encoder>(sourcePixelFormat: OSType,
                                      create: (HEVCChromaSampling) throws -> Encoder) throws -> Encoder {
        if let chroma { return try create(chroma) }
        if HEVCChromaSampling.preferred(for: sourcePixelFormat) == .yuv422 {
            if allows422 {
                do {
                    let encoder = try create(.yuv422)
                    chroma = .yuv422
                    return encoder
                } catch {
                    // The factory must release the failed hardware session before
                    // returning. Do not run an extra encoder alongside the stream.
                    fallbackReason = error.localizedDescription
                }
            } else {
                fallbackReason = "turned off in Settings"
            }
        }
        let encoder = try create(.yuv420)
        chroma = .yuv420
        return encoder
    }
}

/// Correct sustained encoder overshoot without a hard DataRateLimits cap: some
/// hardware enforces that cap by dropping pictures. This only adjusts the average
/// request, using complete two-second output windows and a settling interval.
struct HEVCBitrateRegulator {
    private(set) var target: Int
    private(set) var applied: Int
    private(set) var adjustments = 0
    private let windowFrames: Int
    private let frameRate: Double
    private var acceptsAfterFrame = 0
    private var bytes = 0.0
    private var frames = 0
    private var healthyWindows = 0

    init(bitrate: Int, frameRate: Double) {
        target = bitrate
        applied = bitrate
        self.frameRate = frameRate
        windowFrames = max(1, Int(ceil(frameRate * 2)))
    }

    mutating func setTarget(_ value: Int, afterFrame: Int) {
        let scale = Double(applied) / Double(target)
        target = value
        applied = max(min(value, 50_000), min(value, Int(Double(value) * scale)))
        reset(afterFrame: afterFrame)
    }

    mutating func observe(frame: Int, byteCount: Int) -> Int? {
        guard frame > acceptsAfterFrame, byteCount >= 0 else { return nil }
        bytes += Double(byteCount)
        frames += 1
        guard frames >= windowFrames else { return nil }
        let actual = bytes * 8 * frameRate / Double(frames)
        bytes = 0
        frames = 0
        var next = applied
        if actual > Double(target) * 1.35 {
            // Bound each correction so a complex scene cannot collapse quality
            // in one observation. Leave 10% output allowance around the target.
            next = max(min(target, 50_000), Int(Double(applied) * max(0.5, Double(target) * 1.1 / actual)))
            healthyWindows = 0
        } else {
            healthyWindows = actual <= Double(target) * 1.1 ? healthyWindows + 1 : 0
            if healthyWindows >= 5 { next = min(target, Int(ceil(Double(applied) * 1.1))) }
        }
        guard next != applied else { return nil }
        applied = next
        adjustments += 1
        reset(afterFrame: frame)
        return next
    }

    mutating func discarded(afterFrame: Int) { reset(afterFrame: afterFrame) }

    private mutating func reset(afterFrame: Int) {
        acceptsAfterFrame = afterFrame + windowFrames
        bytes = 0
        frames = 0
        healthyWindows = 0
    }
}

enum HEVCEncoderConfiguration {
    static func validate(width: Int, height: Int, frameRate: Double, bitrate: Int,
                         keyframeInterval: Double) throws {
        guard width > 0, width <= Int32.max, height > 0, height <= Int32.max,
              frameRate.isFinite, frameRate > 0, frameRate <= 120, bitrate > 0,
              keyframeInterval.isFinite, keyframeInterval > 0 else {
            throw MediaEncodingError.invalid("Invalid HEVC encoder configuration")
        }
    }

    /// Segments are cut at keyframes forced every `segmentDuration`. The
    /// encoder's own keyframes must land on those same frames, or it emits a
    /// second keyframe shortly before or after each forced one. Use the nearest
    /// interval that divides a segment; longer intervals become one segment.
    static func alignedKeyframeInterval(_ interval: Double, segmentDuration: Double = 2) -> Double {
        guard interval.isFinite, interval > 0, segmentDuration.isFinite, segmentDuration > 0 else {
            return segmentDuration
        }
        return segmentDuration / max(1, (segmentDuration / interval).rounded())
    }

    static func apply(frameRate: Double, bitrate: Int, keyframeInterval: Double,
                      chroma: HEVCChromaSampling = .yuv420,
                      setProperty: (CFString, CFTypeRef) -> OSStatus) throws {
        let keyframeInterval = alignedKeyframeInterval(keyframeInterval)
        let properties: [(CFString, Any)] = [
            (kVTCompressionPropertyKey_ProfileLevel, chroma.profile),
            (kVTCompressionPropertyKey_RealTime, true),
            (kVTCompressionPropertyKey_AverageBitRate, bitrate),
            (kVTCompressionPropertyKey_ExpectedFrameRate, frameRate),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, max(1, Int((frameRate * keyframeInterval).rounded()))),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, keyframeInterval),
            (kVTCompressionPropertyKey_AllowFrameReordering, true),
            (kVTCompressionPropertyKey_AllowOpenGOP, false),
            (kVTCompressionPropertyKey_MaxFrameDelayCount, 8),
            (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_2020),
            (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_2100_HLG),
            (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_2020),
            (kVTCompressionPropertyKey_HDRMetadataInsertionMode, kVTHDRMetadataInsertionMode_Auto)
        ]
        for (key, value) in properties {
            let status = setProperty(key, value as CFTypeRef)
            // Some hardware encoders (including iPhone 12 on iOS 18) advertise
            // this property but reject setting it. Keep their native delay;
            // the limit is an optimization, not a codec/timestamp requirement.
            // All other settings, including Main10 HLG and closed GOPs, remain
            // required, and unexpected failures of the delay setting still fail.
            if key == kVTCompressionPropertyKey_MaxFrameDelayCount,
               status == kVTPropertyNotSupportedErr { continue }
            try checkMediaStatus(status, "Configuring \(chroma == .yuv422 ? "Main42210" : "Main10") HLG encoder property \(key)")
        }
    }
}

/// Owned and called serially by PipelineActor (also usable by offline probes).
final class HEVCVideoEncoder {
    private var session: VTCompressionSession?
    private let output = VideoEncoderOutput()
    private var decodeTimeline: VideoDecodeTimeline
    private var timingFormat: CMFormatDescription?
    private var submittedFrames = 0
    private var emittedFrames = 0
    private(set) var droppedFrames = 0
    /// Failed pictures and dependent output withheld until a confirmed keyframe.
    private(set) var failedFrames = 0
    private(set) var lastFailureStatus: OSStatus?
    private(set) var recoveryDiscardedFrames = 0
    private var recovery: HEVCFrameRecovery
    /// Keyed by the frame number passed through VideoToolbox's frame refcon,
    /// which identifies a dropped frame that has no output sample.
    private var pendingPTS: [Int: CMTime] = [:]
    private var lastSubmittedPTS: CMTime?
    let frameDuration: CMTime
    private(set) var bitrate: Int
    private var bitrateRegulator: HEVCBitrateRegulator
    private let regulatesBitrate: Bool
    var appliedBitrate: Int { bitrateRegulator.applied }
    var bitrateCorrections: Int { bitrateRegulator.adjustments }

    init(width: Int, height: Int, frameRate: Double, bitrate: Int, keyframeInterval: Double = 2,
         chroma: HEVCChromaSampling = .yuv420, regulatesBitrate: Bool = true) throws {
        try HEVCEncoderConfiguration.validate(width: width, height: height, frameRate: frameRate,
                                             bitrate: bitrate, keyframeInterval: keyframeInterval)
        self.bitrate = bitrate
        self.regulatesBitrate = regulatesBitrate
        bitrateRegulator = HEVCBitrateRegulator(bitrate: bitrate, frameRate: frameRate)
        let duration = CMTime(seconds: 1 / frameRate, preferredTimescale: 90_000)
        frameDuration = duration
        decodeTimeline = VideoDecodeTimeline(frameDuration: duration)
        // Bound recovery to two seconds' worth of callbacks if keyframe
        // requests never produce usable output.
        recovery = HEVCFrameRecovery(maximumWaitingFrames: max(1, Int(ceil(frameRate * 2))))
        var created: VTCompressionSession?
        let creationStatus = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: chroma.pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: { refcon, frameRefcon, status, flags, sample in
                guard let refcon else { return }
                Unmanaged<VideoEncoderOutput>.fromOpaque(refcon).takeUnretainedValue()
                    .receive(status: status, flags: flags, frame: Int(bitPattern: frameRefcon), sample: sample)
            },
            refcon: Unmanaged.passUnretained(output).toOpaque(), compressionSessionOut: &created
        )
        if creationStatus != noErr {
            if let created { VTCompressionSessionInvalidate(created) }
            try checkMediaStatus(creationStatus, "Creating HEVC encoder")
        }
        guard let created else { throw MediaEncodingError.invalid("No HEVC encoder was created") }
        session = created
        do {
            try HEVCEncoderConfiguration.apply(frameRate: frameRate, bitrate: bitrate,
                                                keyframeInterval: keyframeInterval, chroma: chroma) { key, value in
                VTSessionSetProperty(created, key: key, value: value)
            }
            try checkMediaStatus(VTCompressionSessionPrepareToEncodeFrames(created), "Preparing HEVC encoder")
        } catch {
            VTCompressionSessionInvalidate(created)
            session = nil
            throw error
        }
    }

    func setBitrate(_ value: Int) throws {
        guard let session, value > 0 else { throw MediaEncodingError.invalid("HEVC encoder is not active") }
        guard value != bitrate else { return }
        bitrateRegulator.setTarget(value, afterFrame: submittedFrames)
        let applied = regulatesBitrate ? bitrateRegulator.applied : value
        try checkMediaStatus(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                                                 value: applied as CFNumber), "Updating HEVC bitrate")
        bitrate = value
    }

    func encode(_ pixels: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool) throws {
        guard let session else { throw MediaEncodingError.invalid("HEVC encoder is not active") }
        guard presentationTime.isNumeric,
              lastSubmittedPTS.map({ presentationTime > $0 }) ?? true else {
            throw MediaEncodingError.invalid("HEVC input timestamps must increase")
        }
        // Submit the pipeline's original HLG pixel buffer; no RGB intermediate.
        let properties = forceKeyframe || recovery.requiresKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let frame = submittedFrames + 1 // nonzero, so the refcon is never nil
        try checkMediaStatus(VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixels, presentationTimeStamp: presentationTime, duration: frameDuration,
            frameProperties: properties, sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: frame), infoFlagsOut: nil
        ), "Submitting HEVC frame")
        // Keep requesting recovery until a callback confirms a keyframe.
        decodeTimeline.submitted(presentationTime)
        pendingPTS[frame] = presentationTime
        submittedFrames += 1
        lastSubmittedPTS = presentationTime
    }

    func takeOutput(adjustsBitrate: Bool = true) throws -> [CMSampleBuffer] {
        var samples: [CMSampleBuffer] = []
        for event in output.take() {
            switch event {
            case .encoded(let frame, let sample):
                guard let pts = pendingPTS.removeValue(forKey: frame) else {
                    throw MediaEncodingError.invalid("The HEVC encoder returned an unknown frame")
                }
                guard try recovery.shouldEmit(isKeyframe: EncodedSampleAdapter.isRandomAccess(sample)) else {
                    try decodeTimeline.dropped(presentationTime: pts)
                    bitrateRegulator.discarded(afterFrame: submittedFrames)
                    recoveryDiscardedFrames += 1
                    continue
                }
                samples.append(try normalizeDecodeTime(sample))
                emittedFrames += 1
                if regulatesBitrate, adjustsBitrate, let session,
                   let adjusted = bitrateRegulator.observe(frame: frame, byteCount: CMSampleBufferGetTotalSampleSize(sample)) {
                    try checkMediaStatus(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                                                             value: adjusted as CFNumber), "Correcting HEVC bitrate overshoot")
                }
            case .dropped(let frame):
                guard let pts = pendingPTS.removeValue(forKey: frame) else {
                    throw MediaEncodingError.invalid("The HEVC encoder dropped an unknown frame")
                }
                try recovery.discarded()
                bitrateRegulator.discarded(afterFrame: submittedFrames)
                try decodeTimeline.dropped(presentationTime: pts)
                droppedFrames += 1
            case .failed(let frame, let status):
                lastFailureStatus = status
                guard let pts = pendingPTS.removeValue(forKey: frame) else {
                    throw MediaEncodingError.operation("HEVC encoding", status)
                }
                try recovery.failed(status)
                bitrateRegulator.discarded(afterFrame: submittedFrames)
                try decodeTimeline.dropped(presentationTime: pts)
                failedFrames += 1
            }
        }
        return samples
    }

    func finish() throws -> [CMSampleBuffer] {
        guard let session else { return [] }
        defer { VTCompressionSessionInvalidate(session); self.session = nil }
        try checkMediaStatus(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid),
                             "Draining HEVC encoder")
        let samples = try takeOutput(adjustsBitrate: false)
        guard emittedFrames + droppedFrames + failedFrames + recoveryDiscardedFrames == submittedFrames else {
            throw MediaEncodingError.invalid("The HEVC encoder did not return every submitted frame")
        }
        return samples
    }

    private func normalizeDecodeTime(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        // Parse once per format change. MaxFrameDelayCount controls how long the
        // encoder can work, not how many decoded pictures the receiver can hold.
        guard let format = CMSampleBufferGetFormatDescription(sample) else {
            throw MediaEncodingError.invalid("HEVC output has no format description")
        }
        if timingFormat.map({ CFEqual($0, format) }) != true {
            let configuration = try EncodedSampleAdapter.hevcConfiguration(format)
            let limits = try HEVCReordering(sequenceParameterSets: configuration.sequenceParameterSets)
            try decodeTimeline.configure(reorderFrames: limits.reorderFrames)
            timingFormat = format
        }
        // Preserve presentation timestamps and compressed bytes.
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let dts = try decodeTimeline.next(presentationTime: pts)
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: pts, decodeTimeStamp: dts)
        var result: CMSampleBuffer?
        try checkMediaStatus(CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &result), "Normalizing HEVC decoding time")
        guard let result else { throw MediaEncodingError.invalid("Missing timed HEVC sample") }
        return result
    }

    deinit { if let session { VTCompressionSessionInvalidate(session) } }
}

enum EncodedSampleAdapter {
    static func isRandomAccess(_ buffer: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
        return !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    static func hevcConfiguration(_ format: CMFormatDescription) throws -> HEVCDecoderConfiguration {
        var count = 0
        var length: Int32 = 0
        try checkMediaStatus(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &length
        ), "Reading HEVC configuration")
        var sets: [Int: [Data]] = [:]
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            try checkMediaStatus(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ), "Reading HEVC parameter set")
            guard let pointer, size >= 2 else { throw MediaEncodingError.invalid("Empty HEVC parameter set") }
            sets[Int((pointer[0] >> 1) & 0x3f), default: []].append(Data(bytes: pointer, count: size))
        }
        guard let vps = sets[32], let sps = sets[33], let pps = sets[34] else {
            throw MediaEncodingError.invalid("Incomplete HEVC parameter sets")
        }
        return HEVCDecoderConfiguration(nalUnitLengthSize: Int(length), videoParameterSets: vps,
                                        sequenceParameterSets: sps, pictureParameterSets: pps,
                                        prefixSEIUnits: sets[39] ?? [])
    }

    static func sample(_ buffer: CMSampleBuffer, kind: ISOBMFFTrackKind, fallbackDuration: CMTime? = nil) throws -> EncodedMediaSample {
        guard CMSampleBufferGetNumSamples(buffer) == 1,
              let block = CMSampleBufferGetDataBuffer(buffer) else {
            throw MediaEncodingError.invalid("Expected one compressed access unit")
        }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        try data.withUnsafeMutableBytes {
            try checkMediaStatus(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count,
                                                            destination: $0.baseAddress!), "Reading compressed sample")
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        let rawDTS = CMSampleBufferGetDecodeTimeStamp(buffer)
        let dts = rawDTS.isNumeric ? rawDTS : pts
        let rawDuration = CMSampleBufferGetDuration(buffer)
        let duration = rawDuration.isNumeric && rawDuration > .zero ? rawDuration : (fallbackDuration ?? .invalid)
        guard pts.isNumeric, dts.isNumeric, duration.isNumeric, duration > .zero else {
            throw MediaEncodingError.invalid("Invalid compressed sample timestamps")
        }
        return EncodedMediaSample(
            trackID: kind == .video ? 1 : 2, kind: kind, timescale: 90_000,
            decodeTime: CMTimeConvertScale(dts, timescale: 90_000, method: .roundHalfAwayFromZero).value,
            presentationTime: CMTimeConvertScale(pts, timescale: 90_000, method: .roundHalfAwayFromZero).value,
            duration: CMTimeConvertScale(duration, timescale: 90_000, method: .roundHalfAwayFromZero).value,
            isRandomAccess: isRandomAccess(buffer), data: data
        )
    }
}

/// AAC-LC encoding with explicit packet timing. Encoder priming is represented
/// on the shared timeline rather than shifting audio relative to video.
final class AACAudioEncoder {
    private let channels: Int
    private let bitratePerChannel: Int
    private let sampleRate: Double
    private var converter: AVAudioConverter?
    private(set) var inputFormat: AVAudioFormat?
    private var timeline: AudioSampleTimeline?
    private var repair: AudioCaptureRepair?
    private(set) var acceptedInput = false
    var inputEndPTS: CMTime? { repair?.expectedPTS }
    private var outputFrames: Int64 = 0
    private var outputEnd: CMTime?
    private var formatDescription: CMAudioFormatDescription?
    private(set) var configuration: AACDecoderConfiguration?
    /// AAC priming is counted in output frames, whatever the input rate; the
    /// converter compensates for its own resampling delay.
    var primingDuration: Double {
        guard let converter else { return 0 }
        return Double(converter.primeInfo.leadingFrames) / sampleRate
    }

    init(channels: Int, bitratePerChannel: Int, sampleRate: Double = 44_100) {
        self.channels = channels
        self.bitratePerChannel = bitratePerChannel
        self.sampleRate = sampleRate
    }

    /// Encode silence once for recording-only gap padding. Healthy AAC packets
    /// remain untouched, and no extra converter runs during normal capture.
    static func silencePacket(matching format: CMAudioFormatDescription) throws -> CMSampleBuffer {
        guard let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
            throw MediaEncodingError.invalid("Recording gap padding has no audio description")
        }
        let asbd = description.pointee
        guard asbd.mFormatID == kAudioFormatMPEG4AAC,
              asbd.mFramesPerPacket == 0 || asbd.mFramesPerPacket == 1024,
              asbd.mSampleRate.isFinite, (8_000...96_000).contains(asbd.mSampleRate),
              asbd.mChannelsPerFrame == 1 || asbd.mChannelsPerFrame == 2,
              let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                                           channels: asbd.mChannelsPerFrame),
              let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 4096) else {
            throw MediaEncodingError.invalid("Recording gap padding requires mono or stereo AAC-LC (format \(asbd.mFormatID), frames \(asbd.mFramesPerPacket), rate \(asbd.mSampleRate), channels \(asbd.mChannelsPerFrame))")
        }
        pcm.frameLength = pcm.frameCapacity
        for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        let encoder = AACAudioEncoder(channels: Int(asbd.mChannelsPerFrame),
            bitratePerChannel: min(64_000, Int(asbd.mSampleRate * 2)), sampleRate: asbd.mSampleRate)
        try encoder.configure(pcmFormat)
        try encoder.timeline?.append(presentationTime: .zero, frames: Int(pcm.frameLength))
        let packets = try encoder.convert(pcm, finishing: false) + encoder.finish()
        guard packets.count >= 3 else { throw MediaEncodingError.invalid("Could not encode recording silence") }
        // Select an interior packet, away from encoder priming and final padding.
        let payload = try EncodedSampleAdapter.sample(packets[packets.count / 2], kind: .audio).data
        return try encoder.makePacket(payload, format: format, pts: .zero, frames: 1024)
    }

    func encode(_ sample: CMSampleBuffer, basePTS: CMTime) throws -> [CMSampleBuffer] {
        acceptedInput = false
        guard let description = CMSampleBufferGetFormatDescription(sample) else {
            throw MediaEncodingError.invalid("Audio has no format description")
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let pts = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), basePTS)
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, Double(count) <= format.sampleRate else { throw CaptureContinuityError.invalidTiming }
        var result: [CMSampleBuffer] = []
        if converter == nil { try configure(format) }
        else if inputFormat != format { result = try restartConverter(for: format) }
        guard let plan = try repair?.plan(pts: pts, frames: count) else { return result }
        result += try silence(frames: plan.silenceFrames, at: plan.silencePTS)
        let remaining = count - plan.trimFrames
        try timeline?.append(presentationTime: plan.inputPTS, frames: remaining)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(remaining)) else {
            throw MediaEncodingError.invalid("Could not allocate audio input buffer")
        }
        pcm.frameLength = AVAudioFrameCount(remaining)
        try checkMediaStatus(CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: Int32(plan.trimFrames), frameCount: Int32(remaining), into: pcm.mutableAudioBufferList
        ), "Copying microphone PCM")
        result += try convert(pcm, finishing: false)
        repair?.accepted(pts: plan.inputPTS, frames: remaining)
        acceptedInput = true
        return result
    }

    func fillSilence(until pts: CMTime) throws -> [CMSampleBuffer] {
        guard let inputFormat, let start = repair?.expectedPTS else { return [] }
        let duration = CMTimeSubtract(pts, start).seconds
        guard duration > 0 else { return [] }
        guard duration <= CaptureLiveness.concealmentLimit else { throw CaptureContinuityError.discontinuity }
        return try silence(frames: Int((duration * inputFormat.sampleRate).rounded(.down)), at: start)
    }

    private func silence(frames: Int, at start: CMTime) throws -> [CMSampleBuffer] {
        guard let inputFormat, frames > 0 else { return [] }
        var result: [CMSampleBuffer] = []
        var offset = 0
        while offset < frames {
            let count = min(1024, frames - offset)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)) else {
                throw MediaEncodingError.invalid("Could not allocate silence buffer")
            }
            pcm.frameLength = AVAudioFrameCount(count)
            for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
                if let bytes = buffer.mData { memset(bytes, 0, Int(buffer.mDataByteSize)) }
            }
            let pts = CMTimeAdd(start, CMTime(seconds: Double(offset) / inputFormat.sampleRate, preferredTimescale: 90_000))
            try timeline?.append(presentationTime: pts, frames: count)
            result += try convert(pcm, finishing: false)
            repair?.accepted(pts: pts, frames: count)
            offset += count
        }
        return result
    }

    func finish() throws -> [CMSampleBuffer] {
        guard converter != nil else { return [] }
        return try convert(nil, finishing: true)
    }

    /// A route change (USB microphone, AirPods switching to HFP, another sample
    /// rate) changes only the PCM input. The AAC output, its AudioSpecificConfig
    /// and format description stay the same: drain the previous converter, then
    /// continue the same timeline with a new one.
    private func restartConverter(for input: AVAudioFormat) throws -> [CMSampleBuffer] {
        let inputEnd = repair?.expectedPTS
        let tail = try finish()
        try configure(input)
        // The new converter primes again before its first input sample. Resume
        // input only after the drained tail plus that priming, since packet
        // timestamps must not overlap or step back. This skips a few dozen
        // milliseconds of new input rather than shifting audio against video.
        if let end = [outputEnd, inputEnd].compactMap({ $0 }).max() {
            let resume = CMTimeAdd(end, CMTime(seconds: primingDuration, preferredTimescale: 90_000))
            repair?.accepted(pts: resume, frames: 0) // earlier input is then late and trimmed
        }
        return tail
    }

    private func configure(_ input: AVAudioFormat) throws {
        guard channels == 1 || channels == 2,
              let output = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                   AVSampleRateKey: sampleRate,
                                                   AVNumberOfChannelsKey: channels]),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw MediaEncodingError.invalid("Could not configure AAC encoder")
        }
        // Without downmix, a mono preset keeps only the first (left) channel of
        // stereo capture. Mono input is already duplicated for stereo output.
        converter.downmix = input.channelCount > AVAudioChannelCount(channels)
        converter.bitRate = bitratePerChannel * channels
        converter.bitRateStrategy = AVAudioBitRateStrategy_LongTermAverage
        converter.primeMethod = .normal
        self.converter = converter
        inputFormat = input
        timeline = AudioSampleTimeline(sourceSampleRate: input.sampleRate)
        repair = AudioCaptureRepair(sampleRate: input.sampleRate)
        outputFrames = 0
        let rates: [Double] = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
        guard let frequencyIndex = rates.firstIndex(of: sampleRate) else {
            throw MediaEncodingError.invalid("Unsupported AAC sample rate")
        }
        let config = UInt16((2 << 11) | (frequencyIndex << 7) | (channels << 3))
        configuration = AACDecoderConfiguration(audioSpecificConfig: Data([UInt8(config >> 8), UInt8(config & 255)]),
            audioObjectType: 2, samplingFrequencyIndex: UInt8(frequencyIndex), sampleRate: UInt32(sampleRate),
            channelConfiguration: UInt8(channels))
    }

    private func convert(_ input: AVAudioPCMBuffer?, finishing: Bool) throws -> [CMSampleBuffer] {
        guard let converter else { return [] }
        let source = PCMConverterInput(input, finishing: finishing)
        var result: [CMSampleBuffer] = []
        while true {
            let output = AVAudioCompressedBuffer(format: converter.outputFormat, packetCapacity: 32,
                                                 maximumPacketSize: converter.maximumOutputPacketSize)
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                source.take(status: inputStatus)
            }
            if let error { throw error }
            if status == .error { throw MediaEncodingError.invalid("AAC conversion failed") }
            if output.packetCount > 0 {
                let description = try makeFormatDescription(converter)
                guard let packets = output.packetDescriptions else { throw MediaEncodingError.invalid("AAC packets have no sizes") }
                for index in 0..<Int(output.packetCount) {
                    let packet = packets[index]
                    let frames = packet.mVariableFramesInPacket == 0 ? 1024 : Int64(packet.mVariableFramesInPacket)
                    // Priming precedes the first input sample in output frames.
                    guard let pts = timeline?.presentationTime(
                        outputFrame: outputFrames - Int64(converter.primeInfo.leadingFrames), outputSampleRate: sampleRate
                    ) else { throw MediaEncodingError.invalid("AAC output has no source timing") }
                    let bytes = Data(bytes: output.data.advanced(by: Int(packet.mStartOffset)), count: Int(packet.mDataByteSize))
                    result.append(try makePacket(bytes, format: description, pts: pts, frames: frames))
                    outputFrames += frames
                    outputEnd = CMTimeAdd(pts, CMTime(value: frames, timescale: Int32(sampleRate)))
                }
            }
            if status == .inputRanDry || status == .endOfStream { return result }
            if output.packetCount == 0 { return result }
        }
    }

    private func makeFormatDescription(_ converter: AVAudioConverter) throws -> CMAudioFormatDescription {
        if let formatDescription { return formatDescription }
        var description: CMAudioFormatDescription?
        let cookie = converter.magicCookie ?? Data()
        try cookie.withUnsafeBytes {
            try checkMediaStatus(CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: converter.outputFormat.streamDescription, layoutSize: 0, layout: nil,
                magicCookieSize: $0.count, magicCookie: $0.baseAddress, extensions: nil, formatDescriptionOut: &description
            ), "Creating AAC format description")
        }
        guard let description else { throw MediaEncodingError.invalid("Missing AAC format description") }
        formatDescription = description
        return description
    }

    private func makePacket(_ data: Data, format: CMAudioFormatDescription, pts: CMTime, frames: Int64) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        try checkMediaStatus(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
            blockLength: data.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: 0, blockBufferOut: &block), "Allocating AAC packet")
        guard let block else { throw MediaEncodingError.invalid("Missing AAC packet memory") }
        try data.withUnsafeBytes {
            try checkMediaStatus(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: $0.count), "Copying AAC packet")
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: frames, timescale: Int32(sampleRate)),
                                       presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = data.count
        var buffer: CMSampleBuffer?
        try checkMediaStatus(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &buffer), "Creating AAC sample buffer")
        guard let buffer else { throw MediaEncodingError.invalid("Missing AAC sample buffer") }
        return buffer
    }
}

/// Maps encoder output back to capture timestamps, including resampling and
/// priming. Keeping recent anchors avoids accumulating microphone clock drift
/// over a long event. The compressed packets themselves are not resampled again.
struct AudioSampleTimeline {
    private struct Anchor { let frame: Int64; let pts: CMTime }
    let sourceSampleRate: Double
    private var anchors: [Anchor] = []
    private var inputFrames: Int64 = 0
    private var expectedNextPTS: CMTime?
    private var lastPTS: CMTime?

    init(sourceSampleRate: Double) {
        self.sourceSampleRate = sourceSampleRate
    }

    mutating func append(presentationTime: CMTime, frames: Int) throws {
        guard presentationTime.isNumeric, frames > 0 else {
            throw MediaEncodingError.invalid("Invalid microphone timing")
        }
        if let lastPTS, presentationTime <= lastPTS {
            throw MediaEncodingError.invalid("Microphone timestamps must increase")
        }
        if let expectedNextPTS, abs(CMTimeSubtract(presentationTime, expectedNextPTS).seconds) >= 0.001 {
            throw MediaEncodingError.invalid("Microphone timestamps became discontinuous")
        }
        anchors.append(Anchor(frame: inputFrames, pts: presentationTime))
        lastPTS = presentationTime
        inputFrames += Int64(frames)
        expectedNextPTS = CMTimeAdd(presentationTime, CMTime(seconds: Double(frames) / sourceSampleRate,
                                                            preferredTimescale: 90_000))
    }

    mutating func presentationTime(outputFrame: Int64, outputSampleRate: Double, leadingInputFrames: Int64 = 0) -> CMTime? {
        let sourceFrame = Double(outputFrame) * sourceSampleRate / outputSampleRate - Double(leadingInputFrames)
        while anchors.count > 1, Double(anchors[1].frame) <= sourceFrame { anchors.removeFirst() }
        guard let anchor = anchors.first else { return nil }
        return CMTimeAdd(anchor.pts, CMTime(seconds: (sourceFrame - Double(anchor.frame)) / sourceSampleRate,
                                           preferredTimescale: 90_000))
    }
}

private final class PCMConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private var input: AVAudioPCMBuffer?
    private let finishing: Bool

    init(_ input: AVAudioPCMBuffer?, finishing: Bool) {
        self.input = input
        self.finishing = finishing
    }

    func take(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            if let input {
                self.input = nil
                status.pointee = .haveData
                return input
            }
            status.pointee = finishing ? .endOfStream : .noDataNow
            return nil
        }
    }
}
