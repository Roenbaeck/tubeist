import AVFoundation
import Testing
@testable import Tubeist

struct CaptureBufferingTests {
    @Test(arguments: [30, 60])
    func videoTimingPreservesTheOriginalSampleAndArrival(frameRate: Int) throws {
        var pixels: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess)
        let buffer = try #require(pixels)
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(frameRate)),
            presentationTimeStamp: CMTime(value: 123, timescale: 1), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        let original = try #require(sample)
        let wrapped = SendableSampleBuffer(value: original, receivedAt: 12)
        #expect(wrapped.value === original)
        #expect(CMSampleBufferGetPresentationTimeStamp(wrapped.value).seconds == 123)
        #expect(wrapped.mailboxTiming.receivedAt == 12)
        #expect(abs(wrapped.mailboxTiming.duration - 1 / Double(frameRate)) < 0.000_001)
    }

    @Test(arguments: [44100.0, 48000.0])
    func audioTimingCountsTheEntirePCMBlock(sampleRate: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let count = 1024
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: CMTime(value: 123, timescale: 1), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
        let wrapped = SendableSampleBuffer(value: try #require(sample), receivedAt: 12)
        #expect(abs(wrapped.mailboxTiming.duration - Double(count) / sampleRate) < 0.000_001)
        #expect(CMSampleBufferGetPresentationTimeStamp(wrapped.value).seconds == 123)
        #expect(wrapped.mailboxTiming.receivedAt == 12)
    }
}
