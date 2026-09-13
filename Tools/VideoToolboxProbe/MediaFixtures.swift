import AVFoundation
import Foundation

final class RecordingCollector: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var callbacks = 0

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        lock.withLock { bytes.append(data); callbacks += 1 }
    }

    func save(to url: URL) throws {
        try lock.withLock {
            precondition(callbacks > 1, "Recording writer did not produce fragments")
            try bytes.write(to: url)
        }
    }
}

enum ProbeMediaFixtures {
    static func makePixels(frame: Int) throws -> CVPixelBuffer {
        var pixels: CVPixelBuffer?
        try checkMediaStatus(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), "Creating test pixels")
        guard let pixels else { fatalError("Missing pixels") }
        CVPixelBufferLockBaseAddress(pixels, [])
        for plane in 0..<2 {
            let pointer = CVPixelBufferGetBaseAddressOfPlane(pixels, plane)!.assumingMemoryBound(to: UInt16.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) / 2
            let height = CVPixelBufferGetHeightOfPlane(pixels, plane)
            for y in 0..<height {
                for x in 0..<320 {
                    let value = plane == 0 ? 64 + ((x + y + frame * 7) % 877) : 512 + ((x + frame) % 160) - 80
                    pointer[y * stride + x] = UInt16(value << 6)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for (key, value) in [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020)
        ] { CVBufferSetAttachment(pixels, key, value, .shouldPropagate) }
        return pixels
    }

    static func makeAudio(offset: Int, frames: Int, rate: Double) throws -> CMSampleBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 {
            for index in 0..<frames {
                let time = Double(offset + index) / rate
                pcm.floatChannelData![channel][index] = time < 0.25 ? 0 : Float(sin(time * 2 * .pi * 1000) * 0.2)
            }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
                                       presentationTimeStamp: CMTime(value: Int64(offset), timescale: Int32(rate)), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        try checkMediaStatus(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &buffer), "Creating test audio")
        try checkMediaStatus(CMSampleBufferSetDataBufferFromAudioBufferList(buffer!, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList), "Copying test audio")
        return buffer!
    }
}
