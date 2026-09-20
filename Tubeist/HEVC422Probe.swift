#if DEBUG
import AVFoundation
import SwiftUI
import VideoToolbox

/// Explicit offline experiment. No camera, microphone, account, or upload access.
enum HEVC422Probe {
    static var isRequested: Bool { CommandLine.arguments.contains("-hevc-422-probe") }

    static func run() async -> String {
        let folder = URL.documentsDirectory.appendingPathComponent("HEVC422Probe/\(UUID().uuidString)")
        var lines = ["HEVC automatic chroma selection probe", "\(ProcessInfo.processInfo.operatingSystemVersionString)"]
        func report(_ text: String) {
            lines.append(text)
            print("HEVC422_PROBE \(text)")
            // Save progress even if a later hardware trial fails.
            try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent("report.txt"),
                                                    atomically: true, encoding: .utf8)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (width, height, fps) in [(1920, 1080, 30), (3840, 2160, 60)] {
                for sourceChroma in [HEVCChromaSampling.yuv420, .yuv422] {
                    let name = "\(width)x\(height)-\(fps)-\(sourceChroma == .yuv422 ? "422" : "420")"
                    report("START \(name); hardware required; 20 Mbps; HLG/BT.2020")
                    do {
                        let result = try await encode(width: width, height: height, fps: fps,
                                                     sourceChroma: sourceChroma,
                                                     destination: folder.appendingPathComponent(name + ".hevc"))
                        report("ENCODE PASS \(name): \(result.count) frames; selected \(result.chroma.rawValue). Verify chroma and bit depth with ffprobe.")
                    } catch {
                        report("ENCODE FAIL \(name): \(error.localizedDescription)")
                    }
                }
            }
            report("COMPLETE; artifacts in Documents/HEVC422Probe/\(folder.lastPathComponent)")
        } catch {
            report("PROBE FAILED: \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }

    private static func encode(width: Int, height: Int, fps: Int, sourceChroma: HEVCChromaSampling,
                               destination: URL) async throws -> (count: Int, chroma: HEVCChromaSampling) {
        // Exercise the same automatic selection and fallback as a normal stream.
        let format = sourceChroma.pixelFormat
        var selection = HEVCEncoderSelection()
        let encoder = try selection.makeEncoder(sourcePixelFormat: format) { chroma in
            try HEVCVideoEncoder(width: width, height: height, frameRate: Double(fps),
                                 bitrate: 20_000_000, chroma: chroma)
        }
        var pool: CVPixelBufferPool?
        try checkMediaStatus(CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: format, kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary, &pool), "Creating probe pixel pool")
        guard let pool else { throw MediaEncodingError.invalid("Missing probe pixel pool") }
        try Data().write(to: destination)
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        var count = 0
        func receive(_ buffers: [CMSampleBuffer]) throws {
            for buffer in buffers {
                guard let description = CMSampleBufferGetFormatDescription(buffer) else {
                    throw MediaEncodingError.invalid("Missing encoded format")
                }
                let config = try EncodedSampleAdapter.hevcConfiguration(description)
                let sample = try EncodedSampleAdapter.sample(buffer, kind: .video,
                                                             fallbackDuration: encoder.frameDuration)
                var annexB = Data()
                if sample.isRandomAccess {
                    for parameter in config.videoParameterSets + config.sequenceParameterSets + config.pictureParameterSets {
                        annexB.append(contentsOf: [0, 0, 0, 1])
                        annexB.append(parameter)
                    }
                }
                var offset = 0
                while offset < sample.data.count {
                    guard config.nalUnitLengthSize <= sample.data.count - offset else {
                        throw MediaEncodingError.invalid("Truncated probe NAL length")
                    }
                    let length = sample.data[offset..<(offset + config.nalUnitLengthSize)].reduce(0) { ($0 << 8) | Int($1) }
                    offset += config.nalUnitLengthSize
                    guard length > 0, length <= sample.data.count - offset else {
                        throw MediaEncodingError.invalid("Truncated probe NAL payload")
                    }
                    annexB.append(contentsOf: [0, 0, 0, 1])
                    annexB.append(sample.data[offset..<(offset + length)])
                    offset += length
                }
                try file.write(contentsOf: annexB)
                count += 1
            }
        }

        let frames = fps * 3
        let start = ContinuousClock.now
        for frame in 0..<frames {
            try Task.checkCancellation()
            var pixels: CVPixelBuffer?
            try checkMediaStatus(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                [kCVPixelBufferPoolAllocationThresholdKey: 16] as CFDictionary, &pixels), "Allocating probe pixels")
            guard let pixels else { throw MediaEncodingError.invalid("Missing probe pixels") }
            try checkMediaStatus(CVPixelBufferLockBaseAddress(pixels, []), "Locking probe pixels")
            for plane in 0..<CVPixelBufferGetPlaneCount(pixels) {
                let base = CVPixelBufferGetBaseAddressOfPlane(pixels, plane)!.assumingMemoryBound(to: UInt16.self)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) / 2
                for row in 0..<CVPixelBufferGetHeightOfPlane(pixels, plane) {
                    // Coloured horizontal bands exercise the extra chroma rows.
                    let value = plane == 0 ? 64 + (row + frame * 7) % 877 : 256 + (row + frame) % 513
                    (base + row * stride).update(repeating: UInt16(value << 6), count: stride)
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            for (key, value) in [
                (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020),
                (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG),
                (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020)
            ] { CVBufferSetAttachment(pixels, key, value, .shouldPropagate) }
            try encoder.encode(pixels, presentationTime: CMTime(value: Int64(frame), timescale: Int32(fps)),
                               forceKeyframe: frame % (fps * 2) == 0)
            try receive(encoder.takeOutput())
            try await Task.sleep(until: start.advanced(by: .seconds(Double(frame + 1) / Double(fps))),
                                 clock: .continuous)
        }
        try receive(encoder.finish())
        guard count == frames else { throw MediaEncodingError.invalid("Encoded \(count) of \(frames) probe frames") }
        return (count, selection.chroma!)
    }
}

struct HEVC422ProbeView: View {
    @State private var result = "Testing HEVC hardware encoding…"
    var body: some View {
        ScrollView {
            Text(result).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .task {
            let worker = Task.detached { await HEVC422Probe.run() }
            result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        }
    }
}
#endif
