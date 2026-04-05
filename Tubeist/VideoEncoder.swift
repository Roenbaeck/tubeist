//
//  VideoEncoder.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2025-10-05.
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

// MARK: - Types

/// An encoded HEVC video frame ready for MPEG-TS muxing.
struct EncodedVideoFrame {
    /// Annex B bitstream, including VPS/SPS/PPS on keyframes.
    let data: Data
    /// Presentation timestamp in 90kHz ticks, normalized to start from zero.
    let pts: Int64
    /// Decode timestamp in 90kHz ticks (differs from pts when B-frames are present).
    let dts: Int64
    let isKeyFrame: Bool
}

// MARK: - VideoEncoder

/// Wraps `VTCompressionSession` to encode raw `CVPixelBuffer`s into HEVC/H.265.
///
/// The session is configured for:
/// - HEVC Main10 (10-bit), chosen to match the capture pipeline's 10-bit pixel format
/// - HLG HDR color metadata (BT.2020 primaries / ITU-R BT.2100 HLG transfer)
/// - B-frame reordering enabled, so DTS and PTS may differ
/// - Automatic HDR SEI metadata insertion
///
/// VTCompressionSession delivers encoded frames on an internal thread. The output
/// handler calls a static callback function which then safely bridges back to
/// `@PipelineActor` context using `Task { @PipelineActor in }`.
@PipelineActor
final class VideoEncoder {
    private var session: VTCompressionSession?
    private var onEncodedFrame: ((EncodedVideoFrame) -> Void)?
    /// First PTS seen; all subsequent timestamps are offset from this value so
    /// the encoded stream starts from zero regardless of wall-clock origin.
    private var basePTS: CMTime?
    
    // MARK: - Setup / Teardown
    
    /// Creates and configures the compression session.
    ///
    /// - Parameters:
    ///   - width: Frame width in pixels.
    ///   - height: Frame height in pixels.
    ///   - frameRate: Target output frame rate in fps.
    ///   - bitrate: Average video bitrate in bits per second.
    ///   - keyframeInterval: Maximum interval between IDR frames in seconds.
    ///   - onEncodedFrame: Closure called on `@PipelineActor` for each encoded frame.
    func setup(width: Int, height: Int, frameRate: Double,
               bitrate: Int, keyframeInterval: Double,
               onEncodedFrame: @escaping (EncodedVideoFrame) -> Void) {
        self.onEncodedFrame = onEncodedFrame
        self.basePTS = nil
        
        // Request the same 10-bit 4:2:0 format the capture pipeline delivers so
        // VT does not need to do a pixel format conversion internally.
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        
        var sessionRef: VTCompressionSession?
        // The refcon parameter is used to associate this VideoEncoder instance with the VTCompressionSession.
        // This pointer is passed back in the compressionOutputCallback so the callback can refer to this instance.
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: pixelBufferAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: VideoEncoder.compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &sessionRef
        )
        
        guard status == noErr, let compressionSession = sessionRef else {
            LOG("Failed to create VTCompressionSession: \(status)", level: .error)
            return
        }
        session = compressionSession
        
        // Real-time priority ensures frames are not queued up indefinitely.
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // Main10 allows 10-bit color depth; AutoLevel picks the appropriate sub-profile.
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_HEVC_Main10_AutoLevel)
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: bitrate as CFNumber)
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: frameRate as CFNumber)
        
        // Both the interval (in frames) and the duration (in seconds) are set so VT
        // enforces keyframes even when the frame rate changes slightly.
        let maxKeyFrameInterval = Int(ceil(keyframeInterval * frameRate))
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: maxKeyFrameInterval as CFNumber)
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: keyframeInterval as CFNumber)
        // B-frames improve compression efficiency; decoders use DTS to reorder.
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanTrue)
        // Let VT insert HDR SEI NAL units (mastering display info, content light level).
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_HDRMetadataInsertionMode,
                             value: kVTHDRMetadataInsertionMode_Auto)
        
        // BT.2020 primaries + HLG transfer function for HDR 10-bit capture.
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_ColorPrimaries,
                             value: kCVImageBufferColorPrimaries_ITU_R_2020)
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_TransferFunction,
                             value: kCVImageBufferTransferFunction_ITU_R_2100_HLG)
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_YCbCrMatrix,
                             value: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        
        VTCompressionSessionPrepareToEncodeFrames(compressionSession)
        LOG("VideoEncoder session created: \(width)x\(height) @ \(frameRate)fps, \(bitrate)bps", level: .debug)
    }
    
    /// Encodes one raw pixel buffer. The first call establishes the PTS origin.
    ///
    /// - Parameters:
    ///   - pixelBuffer: Uncompressed camera frame.
    ///   - presentationTimeStamp: Wall-clock capture time from AVCaptureSession.
    func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        guard let session else {
            LOG("VideoEncoder: no active session", level: .error)
            return
        }
        
        // Record the first timestamp so all subsequent frames are offset from it,
        // producing a stream that starts at t=0 regardless of when capture began.
        if basePTS == nil {
            basePTS = presentationTimeStamp
        }
        let normalizedPTS = CMTimeSubtract(presentationTimeStamp, basePTS!)
        
        // Passing `.invalid` for duration lets VT infer it from the frame rate;
        // providing an explicit duration can cause audio/video drift when the
        // capture frame rate fluctuates slightly.
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: normalizedPTS,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        
        if status != noErr {
            LOG("VTCompressionSessionEncodeFrame failed: \(status)", level: .error)
        }
    }
    
    /// Flushes all in-flight frames and invalidates the session.
    ///
    /// Passing `.invalid` to `VTCompressionSessionCompleteFrames` signals "flush
    /// everything", not just frames up to a specific timestamp.
    func teardown() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        self.basePTS = nil
        LOG("VideoEncoder session torn down", level: .debug)
    }
    
    // MARK: - Private
    
    /// Processes one encoded sample buffer delivered by VTCompressionSession.
    private func handleEncodedSample(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            LOG("VideoEncoder: no data buffer in encoded sample", level: .error)
            return
        }
        
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                                  totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let pointer = dataPointer else {
            LOG("VideoEncoder: cannot read block buffer", level: .error)
            return
        }
        
        // VT produces HVCC-formatted NALUs (4-byte length prefix). Convert to Annex B
        // (3/4-byte start codes: 00 00 00 01) as required by MPEG-TS PES payloads.
        let rawData = Data(bytes: pointer, count: totalLength)
        let annexBData = hevcToAnnexB(rawData)
        
        // `kCMSampleAttachmentKey_NotSync` is set to true on all non-IDR frames.
        // Its absence (or false) means this is a keyframe / random access point.
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        var isKeyFrame = true
        if let attachments = attachments as? [[CFString: Any]], let first = attachments.first {
            if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
                isKeyFrame = !notSync
            }
        }
        
        // On keyframes, prepend in-band VPS/SPS/PPS parameter sets extracted from
        // the format description. Without them each new segment is undecodable
        // because the codec configuration that was in the moov box (fMP4 path) no
        // longer exists in the raw TS bytestream.
        var fullData: Data
        if isKeyFrame, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var parameterSets = Data()
            var paramSetCount = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDesc, parameterSetIndex: 0,
                                                                parameterSetPointerOut: nil,
                                                                parameterSetSizeOut: nil,
                                                                parameterSetCountOut: &paramSetCount,
                                                                nalUnitHeaderLengthOut: nil)
            for i in 0..<paramSetCount {
                var paramSetPointer: UnsafePointer<UInt8>?
                var paramSetSize = 0
                let psStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDesc, parameterSetIndex: i,
                    parameterSetPointerOut: &paramSetPointer,
                    parameterSetSizeOut: &paramSetSize,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil)
                if psStatus == noErr, let ptr = paramSetPointer {
                    parameterSets.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    parameterSets.append(ptr, count: paramSetSize)
                }
            }
            fullData = parameterSets
            fullData.append(annexBData)
        } else {
            fullData = annexBData
        }
        
        // Convert CoreMedia timestamps (arbitrary timescale) to 90kHz ticks.
        // When decode time is not stamped (no B-frames), fall back to PTS.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        let effectiveDTS = dts.isValid ? dts : pts
        
        let pts90k = Int64(CMTimeConvertScale(pts, timescale: 90000, method: .roundHalfAwayFromZero).value)
        let dts90k = Int64(CMTimeConvertScale(effectiveDTS, timescale: 90000, method: .roundHalfAwayFromZero).value)
        
        let frame = EncodedVideoFrame(data: fullData, pts: pts90k, dts: dts90k, isKeyFrame: isKeyFrame)
        onEncodedFrame?(frame)
    }
    
    /// VTCompressionOutputCallback function called by VTCompressionSession when an encoded frame is ready.
    /// Bridges back to @PipelineActor context using Task to safely use actor-isolated properties.
    private static let compressionOutputCallback: VTCompressionOutputCallback = { 
        outputCallback, 
        refcon, 
        status, 
        infoFlags, 
        sampleBuffer in
        
        guard status == noErr else {
            if let refcon = refcon {
                let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
                LOG("Video encoding error: \(status)", level: .error)
            } else {
                LOG("Video encoding error with nil refcon: \(status)", level: .error)
            }
            return
        }
        
        guard let sampleBuffer = sampleBuffer, let refcon = refcon else {
            // If status == noErr but sampleBuffer or refcon is nil, do nothing.
            return
        }
        
        let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
        
        // Retain sampleBuffer to ensure it stays valid during async Task execution
        nonisolated(unsafe) let sendableSampleBuffer = sampleBuffer // removes the need for @preconcurrency

        Task { @PipelineActor in
            encoder.handleEncodedSample(sendableSampleBuffer)
        }
    }
}

