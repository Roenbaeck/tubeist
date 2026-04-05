//
//  AudioEncoder.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2025-10-05.
//

import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia

// MARK: - Types

/// A single AAC frame produced by the encoder, ready for MPEG-TS muxing.
struct EncodedAudioFrame {
    /// Raw AAC frame data without any ADTS header. The muxer adds ADTS before
    /// wrapping in a PES packet so it is not double-counted in the PES length field.
    let data: Data
    /// Presentation timestamp in 90kHz ticks, normalized to start from zero.
    let pts: Int64
}

// MARK: - AudioEncoder

/// Wraps `AudioConverter` to encode raw PCM audio into AAC-LC.
///
/// The converter is created **lazily** on the first sample buffer rather than
/// during `setup`. This is intentional: `AVCaptureSession` may deliver audio in
/// different formats on different devices (Float32 non-interleaved on macOS,
/// Sint16 interleaved on some iOS targets). Reading `CMAudioFormatDescription`
/// from the first live buffer guarantees the converter's input format always
/// exactly matches what the capture session delivers.
///
/// Each call to `encode` may produce multiple AAC frames because a single
/// `CMSampleBuffer` can contain more samples than one 1024-frame AAC window.
/// The encoder iterates in 1024-frame chunks and emits one `EncodedAudioFrame`
/// per chunk with its own interpolated PTS.
@PipelineActor
final class AudioEncoder {
    private var converter: AudioConverterRef?
    private var onEncodedFrame: ((EncodedAudioFrame) -> Void)?
    private var sampleRate: Double = AUDIO_SAMPLE_RATE
    private var channels: Int = DEFAULT_AUDIO_CHANNELS
    private var bitrate: Int = DEFAULT_AUDIO_BITRATE
    /// PTS of the first buffer received; used to normalize the stream to t=0.
    private var basePTS: CMTime?
    /// Reusable scratch buffer for the `AudioConverterFillComplexBuffer` output.
    /// Sized generously: a 128kbps stereo AAC frame is at most ~750 bytes.
    private var aacBuffer = Data(count: 8192)
    private var isSetUp: Bool = false
    /// Cached input format description, read once from the first sample buffer.
    private var inputFormat: AudioStreamBasicDescription?
    
    // MARK: - Setup / Teardown
    
    /// Stores encoding parameters. The actual `AudioConverter` is created on the
    /// first call to `encode` once the live PCM format is known.
    ///
    /// - Parameters:
    ///   - sampleRate: Output sample rate in Hz.
    ///   - channels: Number of audio channels.
    ///   - bitrate: Per-channel target bitrate in bits per second.
    ///   - onEncodedFrame: Closure called on `@PipelineActor` for each AAC frame.
    func setup(sampleRate: Double, channels: Int, bitrate: Int,
               onEncodedFrame: @escaping (EncodedAudioFrame) -> Void) {
        self.onEncodedFrame = onEncodedFrame
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitrate = bitrate
        self.basePTS = nil
        self.isSetUp = true
        LOG("AudioEncoder configured: \(sampleRate)Hz, \(channels)ch, \(bitrate * channels)bps", level: .debug)
    }
    
    /// Tears down the audio converter and resets all state.
    func teardown() {
        if let converter {
            AudioConverterDispose(converter)
        }
        converter = nil
        basePTS = nil
        inputFormat = nil
        isSetUp = false
        LOG("AudioEncoder torn down", level: .debug)
    }
    
    // MARK: - Encoding
    
    /// Encodes all complete 1024-frame AAC windows contained in the PCM buffer.
    ///
    /// Any trailing samples that do not fill a complete packet are discarded; at
    /// typical capture rates the next buffer arrives within ~23 ms and the
    /// accumulated drift is negligible. Incomplete final packets are not buffered
    /// to avoid latency.
    func encode(sampleBuffer: CMSampleBuffer) {
        guard isSetUp else {
            LOG("AudioEncoder: not set up", level: .error)
            return
        }
        
        // Lazily create (and cache) the converter using the live capture format.
        if converter == nil {
            createConverter(from: sampleBuffer)
        }
        
        guard let converter, let inputFormat else {
            LOG("AudioEncoder: no active converter", level: .error)
            return
        }
        
        // Normalize PTS to start from zero on the first buffer received.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if basePTS == nil {
            basePTS = pts
        }
        let normalizedPTS = CMTimeSubtract(pts, basePTS!)
        let pts90k = Int64(CMTimeConvertScale(normalizedPTS, timescale: 90000, method: .roundHalfAwayFromZero).value)
        
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            LOG("AudioEncoder: no data buffer", level: .error)
            return
        }
        
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                                  totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let pointer = dataPointer, totalLength > 0 else {
            LOG("AudioEncoder: cannot read PCM buffer", level: .error)
            return
        }
        
        let pcmData = UnsafeMutableRawPointer(pointer)
        let bytesPerFrame = inputFormat.mBytesPerFrame
        guard bytesPerFrame > 0 else {
            LOG("AudioEncoder: invalid bytes per frame", level: .error)
            return
        }
        let totalFrames = UInt32(totalLength) / bytesPerFrame
        // MPEG-4 AAC uses a fixed 1024-sample transform window at all sample rates.
        let framesPerPacket: UInt32 = 1024
        
        var pcmOffset: UInt32 = 0  // current position in PCM data, in frames
        var framesRemaining = totalFrames
        
        // Produce one AAC frame per 1024-sample window. Partial trailing windows
        // are skipped to keep the loop simple and latency low.
        while framesRemaining >= framesPerPacket {
            let inputBytes = framesPerPacket * bytesPerFrame
            
            var inputBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: inputBytes,
                    mData: pcmData.advanced(by: Int(pcmOffset * bytesPerFrame))
                )
            )
            
            var outputPacketCount: UInt32 = 1
            
            aacBuffer.withUnsafeMutableBytes { rawBufferPointer in
                var outputBufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels),
                        mDataByteSize: UInt32(aacBuffer.count),
                        mData: rawBufferPointer.baseAddress
                    )
                )
                var packetDescription = AudioStreamPacketDescription()
                
                // `AudioConverterFillComplexBuffer` calls the supplied callback
                // **synchronously** to request input data before it returns.
                // The callback simply hands back the pre-built `inputBufferList`
                // via `inUserData`; no async signalling is required.
                let convertStatus = AudioConverterFillComplexBuffer(
                    converter,
                    { (_, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
                        let bufferListPtr = inUserData!.assumingMemoryBound(to: AudioBufferList.self)
                        ioData.pointee.mNumberBuffers = 1
                        ioData.pointee.mBuffers = bufferListPtr.pointee.mBuffers
                        ioNumberDataPackets.pointee = 1024
                        return noErr
                    },
                    &inputBufferList,
                    &outputPacketCount,
                    &outputBufferList,
                    &packetDescription
                )
                
                if convertStatus == noErr, outputPacketCount > 0 {
                    let encodedSize = Int(outputBufferList.mBuffers.mDataByteSize)
                    let encodedData = Data(bytes: rawBufferPointer.baseAddress!, count: encodedSize)
                    
                    // Interpolate the PTS for this chunk: each previous window of
                    // 1024 samples advanced the clock by (1024 / sampleRate) seconds.
                    let chunkPTS = pts90k + Int64(Double(pcmOffset) / sampleRate * 90000.0)
                    
                    onEncodedFrame?(EncodedAudioFrame(data: encodedData, pts: chunkPTS))
                }
            }
            
            pcmOffset += framesPerPacket
            framesRemaining -= framesPerPacket
        }
    }
    
    // MARK: - Private
    
    /// Reads the PCM format from the first live sample buffer and creates the
    /// `AudioConverter` using that exact description as the input format.
    private func createConverter(from sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            LOG("AudioEncoder: no format description in sample buffer", level: .error)
            return
        }
        guard let inputASBD = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            LOG("AudioEncoder: cannot get input ASBD", level: .error)
            return
        }
        inputFormat = inputASBD
        
        // Target: AAC-LC with the requested sample rate, channel count, and bitrate.
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,       // variable — filled in by AudioConverter
            mFramesPerPacket: 1024,   // MPEG-4 AAC fixed window size
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        
        var inputFormatCopy = inputASBD
        var converterRef: AudioConverterRef?
        let status = AudioConverterNew(&inputFormatCopy, &outputFormat, &converterRef)
        guard status == noErr, let conv = converterRef else {
            LOG("Failed to create AudioConverter: \(status)", level: .error)
            return
        }
        converter = conv
        
        // Total bitrate = per-channel rate × channel count.
        var bitrateValue = UInt32(bitrate * channels)
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate,
                                  UInt32(MemoryLayout<UInt32>.size), &bitrateValue)
        
        // Variable bitrate allows the codec to use fewer bits on silent passages.
        var strategy = kAudioCodecBitRateControlMode_Variable
        AudioConverterSetProperty(conv, kAudioCodecPropertyBitRateControlMode,
                                  UInt32(MemoryLayout<UInt32>.size), &strategy)
        
        LOG("AudioEncoder converter created — input: \(inputASBD.mFormatID) \(inputASBD.mBitsPerChannel)bit \(inputASBD.mSampleRate)Hz", level: .debug)
    }
}
