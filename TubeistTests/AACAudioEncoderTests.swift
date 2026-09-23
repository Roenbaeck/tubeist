import AVFoundation
import Testing
@testable import Tubeist

struct AACAudioEncoderTests {
    @Test(arguments: [0, 1])
    func monoPresetsMixBothStereoCaptureChannels(toneChannel: Int) throws {
        // The built-in microphone captures stereo even for mono presets.
        let encoder = AACAudioEncoder(channels: 1, bitratePerChannel: 64_000, sampleRate: 44_100)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        var packets: [CMSampleBuffer] = []
        for block in 0..<47 {
            let start = block * 1024
            let sample = try AACTestAudio.pcm(format, frames: 1024, pts: Double(start) / 48_000) { channel, frame in
                channel == toneChannel ? Float(0.5 * sin(2 * .pi * 440 * Double(start + frame) / 48_000)) : 0
            }
            packets += try encoder.encode(sample, basePTS: .zero)
        }
        packets += try encoder.finish()
        let decoded = try AACTestAudio.decode(packets, channels: 1)
        let energy = decoded[0].reduce(0) { $0 + Double($1 * $1) }
        // (L + R) / 2 halves a one-sided 0.5 tone: about 0.03 per sample.
        let expected = Double(decoded[0].count) * 0.25 * 0.25 / 2
        #expect(energy > expected * 0.5, "Channel \(toneChannel) was not mixed into mono AAC (energy \(energy))")
    }

    @Test(arguments: [1, 2])
    func microphoneFormatChangesContinueTheSameAACStream(channels: Int) throws {
        let encoder = AACAudioEncoder(channels: channels, bitratePerChannel: 64_000, sampleRate: 44_100)
        // Built-in stereo, AirPods in HFP, a USB microphone, then built-in again.
        let inputs: [(rate: Double, channels: AVAudioChannelCount)] = [(48_000, 2), (16_000, 1), (44_100, 1), (48_000, 2)]
        var packets: [CMSampleBuffer] = []
        var switches: [Double] = []
        var time = 3.0
        var configuration: AACDecoderConfiguration?
        for input in inputs {
            switches.append(time)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: input.rate, channels: input.channels))
            for _ in 0..<Int(input.rate / 1024) {
                let start = time
                let sample = try AACTestAudio.pcm(format, frames: 1024, pts: start) { _, frame in
                    let sampleTime: Double = start + Double(frame) / input.rate
                    let phase: Double = 2.0 * Double.pi * 1000.0 * sampleTime
                    return Float(0.2 * sin(phase))
                }
                packets += try encoder.encode(sample, basePTS: .zero)
                time += 1024 / input.rate
            }
            configuration = configuration ?? encoder.configuration
            #expect(encoder.configuration == configuration)
            #expect(encoder.inputFormat == format)
        }
        packets += try encoder.finish()
        #expect(configuration?.channelConfiguration == UInt8(channels))
        #expect(configuration?.sampleRate == 44_100)

        let first = try #require(packets.first.flatMap(CMSampleBufferGetFormatDescription))
        var previousStart = -Double.infinity
        var previousEnd = -Double.infinity
        for packet in packets {
            #expect(CMSampleBufferGetFormatDescription(packet).map { CMFormatDescriptionEqual($0, otherFormatDescription: first) } == true)
            let start = CMSampleBufferGetPresentationTimeStamp(packet).seconds
            let duration = CMSampleBufferGetDuration(packet).seconds
            #expect(abs(duration - 1024 / 44_100) < 1e-6)
            // Monotonic and non-overlapping (beyond sub-millisecond rounding);
            // a restart may leave only a short gap.
            #expect(start > previousStart)
            #expect(start >= previousEnd - 0.001, "Packet at \(start)s overlaps the previous one ending at \(previousEnd)s")
            #expect(start - previousEnd < 0.1 || previousEnd == -.infinity, "Gap before \(start)s")
            previousStart = start
            previousEnd = start + duration
        }
        // Encoding continued after every format change.
        for (index, switchTime) in switches.enumerated() {
            let next = index + 1 < switches.count ? switches[index + 1] : time
            #expect(packets.contains { (switchTime + 0.2..<next).contains(CMSampleBufferGetPresentationTimeStamp($0).seconds) })
        }
        #expect(previousEnd > time - 0.1)
        // The resulting stream decodes without error.
        #expect(try AACTestAudio.decode(packets, channels: channels)[0].count == packets.count * 1024)
    }

    @Test(arguments: [16_000.0, 44_100, 48_000])
    func resampledInputKeepsItsCaptureTime(rate: Double) throws {
        // AAC priming is 2112 output frames at every input rate.
        let encoder = AACAudioEncoder(channels: 1, bitratePerChannel: 64_000, sampleRate: 44_100)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let startTime = 7.0
        let clickFrame = Int(rate * 0.5)
        var packets: [CMSampleBuffer] = []
        for block in 0..<Int(rate / 1024) {
            let start = block * 1024
            let sample = try AACTestAudio.pcm(format, frames: 1024, pts: startTime + Double(start) / rate) { _, frame in
                let offset = start + frame - clickFrame
                return abs(offset) <= 8 ? Float(0.8 * cos(Double(offset) / 8 * .pi / 2)) : 0
            }
            packets += try encoder.encode(sample, basePTS: .zero)
        }
        packets += try encoder.finish()
        let decoded = try AACTestAudio.decode(packets, channels: 1)[0]
        let peak = try #require(decoded.indices.max { abs(decoded[$0]) < abs(decoded[$1]) })
        let packetStart = CMSampleBufferGetPresentationTimeStamp(packets[peak / 1024]).seconds
        let peakTime = packetStart + Double(peak % 1024) / 44_100
        let clickTime = startTime + Double(clickFrame) / rate
        #expect(abs(peakTime - clickTime) < 0.002, "Click decoded at \(peakTime)s instead of \(clickTime)s")
    }
}

enum AACTestAudio {
    static func pcm(_ format: AVAudioFormat, frames: Int, pts: Double,
                    value: (_ channel: Int, _ frame: Int) -> Float) throws -> CMSampleBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<frames { data[channel][frame] = value(channel, frame) }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(format.sampleRate)),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try checkMediaStatus(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), "Creating PCM test sample")
        let result = try #require(sample)
        try checkMediaStatus(CMSampleBufferSetDataBufferFromAudioBufferList(result,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            bufferList: buffer.audioBufferList), "Setting PCM test data")
        return result
    }

    /// Decodes every packet, including priming, as 1024 PCM frames each.
    static func decode(_ packets: [CMSampleBuffer], channels: Int) throws -> [[Float]] {
        let description = try #require(packets.first.flatMap(CMSampleBufferGetFormatDescription))
        let aac = AVAudioFormat(cmAudioFormatDescription: description)
        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                                channels: AVAudioChannelCount(channels), interleaved: false))
        let decoder = try #require(AVAudioConverter(from: aac, to: output))
        var compressed: [AVAudioCompressedBuffer] = []
        for packet in packets {
            let bytes = try EncodedSampleAdapter.sample(packet, kind: .audio).data
            let buffer = AVAudioCompressedBuffer(format: aac, packetCapacity: 1, maximumPacketSize: bytes.count)
            bytes.copyBytes(to: buffer.data.assumingMemoryBound(to: UInt8.self), count: bytes.count)
            buffer.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                          mDataByteSize: UInt32(bytes.count))
            buffer.packetCount = 1
            buffer.byteLength = UInt32(bytes.count)
            compressed.append(buffer)
        }
        let input = CompressedPackets(compressed)
        var result = [[Float]](repeating: [], count: channels)
        while true {
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 4096))
            var error: NSError?
            let status = decoder.convert(to: pcm, error: &error) { _, inputStatus in input.next(inputStatus) }
            if let error { throw error }
            for channel in 0..<channels {
                result[channel] += UnsafeBufferPointer(start: pcm.floatChannelData![channel], count: Int(pcm.frameLength))
            }
            if status == .endOfStream || status == .error || pcm.frameLength == 0 { break }
        }
        return result
    }

    private final class CompressedPackets: @unchecked Sendable {
        private var packets: [AVAudioCompressedBuffer]
        init(_ packets: [AVAudioCompressedBuffer]) { self.packets = packets }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard !packets.isEmpty else {
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return packets.removeFirst()
        }
    }
}
