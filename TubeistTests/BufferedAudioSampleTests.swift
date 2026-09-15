import AVFoundation
import Testing
@testable import Tubeist

struct BufferedAudioSampleTests {
    @Test func bufferedAudioOwnsUnchangedPCMAndPreservesCaptureTiming() throws {
        for interleaved in [false, true] {
            for commonFormat in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16] {
                for rate in [44_100.0, 48_000.0] {
                    let format = try #require(AVAudioFormat(commonFormat: commonFormat,
                        sampleRate: rate, channels: 2, interleaved: interleaved))
                    let frames: AVAudioFrameCount = 137
                    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
                    pcm.frameLength = frames
                    for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
                        let bytes = try #require(buffer.mData).assumingMemoryBound(to: UInt8.self)
                        for index in 0..<Int(buffer.mDataByteSize) { bytes[index] = UInt8(index % 127 + 1) }
                    }
                    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
                        presentationTimeStamp: CMTime(value: 123_457, timescale: 1_000), decodeTimeStamp: .invalid)
                    var source: CMSampleBuffer?
                    try checkMediaStatus(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false,
                        makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
                        sampleCount: Int(frames), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &source), "Creating PCM test sample")
                    let original = try #require(source)
                    try checkMediaStatus(CMSampleBufferSetDataBufferFromAudioBufferList(original,
                        blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
                        bufferList: pcm.audioBufferList), "Setting PCM test data")

                    let expected = try channelBytes(original, format: format)
                    let copy = try BufferedAudioSample.copy(original)
                    #expect(try channelBytes(copy, format: format) == expected)
                    #expect(CMSampleBufferGetFormatDescription(copy) == CMSampleBufferGetFormatDescription(original))
                    #expect(CMSampleBufferGetPresentationTimeStamp(copy) == timing.presentationTimeStamp)
                    #expect(CMSampleBufferGetDuration(copy) == CMSampleBufferGetDuration(original))
                    #expect(CMSampleBufferGetNumSamples(copy) == Int(frames))
                    #expect(!CMSampleBufferGetDecodeTimeStamp(copy).isValid)
                    #expect(CMSampleBufferDataIsReady(copy))

                    // Startup may begin partway through this buffered block.
                    // Cover both planar PCM and absent sample-size metadata,
                    // which CMSampleBufferCopySampleBufferForRange rejects.
                    let skipped = 41
                    let trimmed = try BufferedAudioSample.copy(copy, skippingFrames: skipped)
                    let byteOffset = skipped * Int(format.streamDescription.pointee.mBytesPerFrame)
                    #expect(try channelBytes(trimmed, format: format) == expected.map { Data($0.dropFirst(byteOffset)) })
                    #expect(CMSampleBufferGetNumSamples(trimmed) == Int(frames) - skipped)
                    #expect(CMSampleBufferGetPresentationTimeStamp(trimmed) == CMTimeAdd(
                        timing.presentationTimeStamp, CMTimeMultiply(timing.duration, multiplier: Int32(skipped))))

                    // Reusing the capture storage must not change buffered audio.
                    let block = try #require(CMSampleBufferGetDataBuffer(original))
                    try checkMediaStatus(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block,
                        offsetIntoDestination: 0, dataLength: CMBlockBufferGetDataLength(block)), "Reusing capture storage")
                    #expect(try channelBytes(original, format: format) != expected)
                    #expect(try channelBytes(copy, format: format) == expected)
                }
            }
        }
    }

    private func channelBytes(_ sample: CMSampleBuffer, format: AVAudioFormat) throws -> [Data] {
        let frames = CMSampleBufferGetNumSamples(sample)
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        try checkMediaStatus(CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
            frameCount: Int32(frames), into: pcm.mutableAudioBufferList), "Reading test PCM")
        return UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList).map {
            Data(bytes: $0.mData!, count: Int($0.mDataByteSize))
        }
    }
}
