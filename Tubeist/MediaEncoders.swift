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

/// The callback only stores compressed buffers under a lock. The pipeline
/// drains them in callback order; one unstructured Task per frame could reorder
/// packets and race encoder shutdown.
private final class VideoEncoderOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [CMSampleBuffer] = []
    private var failure: MediaEncodingError?

    func receive(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        lock.withLock {
            if status != noErr { failure = .operation("HEVC encoding", status) }
            else if flags.contains(.frameDropped) { failure = .invalid("The HEVC encoder dropped a frame") }
            else if let sample { samples.append(sample) }
        }
    }

    func take() throws -> [CMSampleBuffer] {
        try lock.withLock {
            if let failure { throw failure }
            let result = samples
            samples.removeAll(keepingCapacity: true)
            return result
        }
    }
}

/// Owned and called serially by PipelineActor (also usable by offline probes).
final class HEVCVideoEncoder {
    private var session: VTCompressionSession?
    private let output = VideoEncoderOutput()
    private let maximumFrameDelay = 8
    private var submittedFrames = 0
    private var emittedFrames = 0
    let frameDuration: CMTime
    private(set) var bitrate: Int

    init(width: Int, height: Int, frameRate: Double, bitrate: Int, keyframeInterval: Double = 2) throws {
        guard width > 0, width <= Int32.max, height > 0, height <= Int32.max,
              frameRate.isFinite, frameRate > 0, frameRate <= 120, bitrate > 0,
              keyframeInterval.isFinite, keyframeInterval > 0 else {
            throw MediaEncodingError.invalid("Invalid HEVC encoder configuration")
        }
        self.bitrate = bitrate
        frameDuration = CMTime(seconds: 1 / frameRate, preferredTimescale: 90_000)
        var created: VTCompressionSession?
        try checkMediaStatus(VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, flags, sample in
                guard let refcon else { return }
                Unmanaged<VideoEncoderOutput>.fromOpaque(refcon).takeUnretainedValue()
                    .receive(status: status, flags: flags, sample: sample)
            },
            refcon: Unmanaged.passUnretained(output).toOpaque(), compressionSessionOut: &created
        ), "Creating HEVC encoder")
        guard let created else { throw MediaEncodingError.invalid("No HEVC encoder was created") }
        session = created
        do {
            try checkMediaStatus(VTSessionSetProperties(created, propertyDictionary: [
                kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main10_AutoLevel,
                kVTCompressionPropertyKey_RealTime: true,
                kVTCompressionPropertyKey_AverageBitRate: bitrate,
                kVTCompressionPropertyKey_ExpectedFrameRate: frameRate,
                kVTCompressionPropertyKey_MaxKeyFrameInterval: Int(ceil(frameRate * min(2, keyframeInterval))),
                kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: min(2, keyframeInterval),
                kVTCompressionPropertyKey_AllowFrameReordering: true,
                kVTCompressionPropertyKey_AllowOpenGOP: false,
                kVTCompressionPropertyKey_MaxFrameDelayCount: maximumFrameDelay,
                kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
                kVTCompressionPropertyKey_HDRMetadataInsertionMode: kVTHDRMetadataInsertionMode_Auto
            ] as CFDictionary), "Configuring Main10 HLG encoder")
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
        try checkMediaStatus(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                                                 value: value as CFNumber), "Updating HEVC bitrate")
        bitrate = value
    }

    func encode(_ pixels: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool) throws {
        guard let session else { throw MediaEncodingError.invalid("HEVC encoder is not active") }
        // Submit the pipeline's original HLG pixel buffer; no RGB intermediate.
        let properties = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        try checkMediaStatus(VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixels, presentationTimeStamp: presentationTime, duration: frameDuration,
            frameProperties: properties, sourceFrameRefcon: nil, infoFlagsOut: nil
        ), "Submitting HEVC frame")
        submittedFrames += 1
    }

    func takeOutput() throws -> [CMSampleBuffer] {
        let samples = try output.take().map(normalizeDecodeTime)
        emittedFrames += samples.count
        return samples
    }

    func finish() throws -> [CMSampleBuffer] {
        guard let session else { return [] }
        defer { VTCompressionSessionInvalidate(session); self.session = nil }
        try checkMediaStatus(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid),
                             "Draining HEVC encoder")
        let samples = try takeOutput()
        guard emittedFrames == submittedFrames else {
            throw MediaEncodingError.invalid("The HEVC encoder did not return every submitted frame")
        }
        return samples
    }

    private func normalizeDecodeTime(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        // VideoToolbox can emit signed composition offsets (PTS < DTS).
        // Transport streams require enough decoding lead, and Apple's HLS MP4
        // profile otherwise shifts video presentation to remove those offsets.
        // The configured compression-window bound provides a fixed safe lead
        // for the whole session, including after bitrate/GOP changes. Only DTS
        // changes: the captured presentation timeline and payload stay intact.
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let sourceDTS = CMSampleBufferGetDecodeTimeStamp(sample)
        let dts = CMTimeSubtract(sourceDTS.isNumeric ? sourceDTS : pts,
                                 CMTimeMultiply(frameDuration, multiplier: Int32(maximumFrameDelay)))
        guard dts <= pts else { throw MediaEncodingError.invalid("HEVC reordering exceeded its configured bound") }
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
                                        sequenceParameterSets: sps, pictureParameterSets: pps)
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
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
        let sync = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        return EncodedMediaSample(
            trackID: kind == .video ? 1 : 2, kind: kind, timescale: 90_000,
            decodeTime: CMTimeConvertScale(dts, timescale: 90_000, method: .roundHalfAwayFromZero).value,
            presentationTime: CMTimeConvertScale(pts, timescale: 90_000, method: .roundHalfAwayFromZero).value,
            duration: CMTimeConvertScale(duration, timescale: 90_000, method: .roundHalfAwayFromZero).value,
            isRandomAccess: sync, data: data
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
    private var inputFormat: AVAudioFormat?
    private var timeline: AudioSampleTimeline?
    private var outputFrames: Int64 = 0
    private var formatDescription: CMAudioFormatDescription?
    private(set) var configuration: AACDecoderConfiguration?
    var primingDuration: Double {
        guard let converter, let inputFormat else { return 0 }
        return Double(converter.primeInfo.leadingFrames) / inputFormat.sampleRate
    }

    init(channels: Int, bitratePerChannel: Int, sampleRate: Double = 44_100) {
        self.channels = channels
        self.bitratePerChannel = bitratePerChannel
        self.sampleRate = sampleRate
    }

    func encode(_ sample: CMSampleBuffer, basePTS: CMTime) throws -> [CMSampleBuffer] {
        guard let description = CMSampleBufferGetFormatDescription(sample) else {
            throw MediaEncodingError.invalid("Audio has no format description")
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        if converter == nil { try configure(format) }
        guard let inputFormat, inputFormat == format else {
            throw MediaEncodingError.invalid("Microphone format changed during encoding")
        }
        let pts = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), basePTS)
        let count = CMSampleBufferGetNumSamples(sample)
        try timeline?.append(presentationTime: pts, frames: count)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw MediaEncodingError.invalid("Could not allocate audio input buffer")
        }
        pcm.frameLength = AVAudioFrameCount(count)
        try checkMediaStatus(CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList
        ), "Copying microphone PCM")
        return try convert(pcm, finishing: false)
    }

    func finish() throws -> [CMSampleBuffer] {
        guard converter != nil else { return [] }
        return try convert(nil, finishing: true)
    }

    private func configure(_ input: AVAudioFormat) throws {
        guard channels == 1 || channels == 2,
              let output = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                   AVSampleRateKey: sampleRate,
                                                   AVNumberOfChannelsKey: channels]),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw MediaEncodingError.invalid("Could not configure AAC encoder")
        }
        converter.bitRate = bitratePerChannel * channels
        converter.bitRateStrategy = AVAudioBitRateStrategy_LongTermAverage
        converter.primeMethod = .normal
        self.converter = converter
        inputFormat = input
        timeline = AudioSampleTimeline(sourceSampleRate: input.sampleRate)
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
                    guard let pts = timeline?.presentationTime(
                        outputFrame: outputFrames, outputSampleRate: sampleRate,
                        leadingInputFrames: Int64(converter.primeInfo.leadingFrames)
                    ) else { throw MediaEncodingError.invalid("AAC output has no source timing") }
                    let bytes = Data(bytes: output.data.advanced(by: Int(packet.mStartOffset)), count: Int(packet.mDataByteSize))
                    result.append(try makePacket(bytes, format: description, pts: pts, frames: frames))
                    outputFrames += frames
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

    init(sourceSampleRate: Double) {
        self.sourceSampleRate = sourceSampleRate
    }

    mutating func append(presentationTime: CMTime, frames: Int) throws {
        guard presentationTime.isNumeric, frames > 0 else {
            throw MediaEncodingError.invalid("Invalid microphone timing")
        }
        if let expectedNextPTS, abs(CMTimeSubtract(presentationTime, expectedNextPTS).seconds) >= 0.1 {
            throw MediaEncodingError.invalid("Microphone timestamps became discontinuous")
        }
        anchors.append(Anchor(frame: inputFrames, pts: presentationTime))
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
