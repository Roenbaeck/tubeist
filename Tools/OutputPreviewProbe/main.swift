// Exercise the production preview pipeline on a Mac GPU, without a phone.
import CoreVideo
import Foundation
import Metal

let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(source: String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8), options: nil)
let pipeline = try MetalOutputPipeline(device: device, library: library)
let width = 64, height = 32
let referencePeak = 1000.0 / 203.0
let formats: [(String, OSType, Bool)] = [
    ("420-full", kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, false),
    ("420-video", kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, true),
    ("422-full", kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, false),
    ("422-video", kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, true),
    ("444-video", kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, true)
]
// Asymmetric rows expose upside-down rendering. Include SDR, colored HDR,
// reference white, peak white and black; each patch is 8 x 8 source pixels.
let patches: [[Double]] = [
    [0,0,0], [0.1,0.1,0.1], [0.3,0.3,0.3], [0.5,0.5,0.5], [0.65,0.65,0.65], [0.75,0.75,0.75], [0.9,0.9,0.9], [1,1,1],
    [0.65,0,0], [0,0.65,0], [0,0,0.65], [0,0.65,0.65], [0.65,0,0.65], [0.65,0.65,0], [0.6,0.4,0.3], [0.35,0.2,0.15],
    [0.95,0.2,0.1], [0.1,0.95,0.2], [0.2,0.1,0.95], [0.1,0.9,0.9], [0.9,0.1,0.9], [0.9,0.9,0.1], [0.7,0.5,0.35], [0.5,0.3,0.2],
    [0.2,0.2,0.2], [0.4,0.4,0.4], [0.6,0.6,0.6], [0.7,0.7,0.7], [0.8,0.8,0.8], [0.85,0.85,0.85], [0.95,0.95,0.95], [0.05,0.05,0.05]
]

func makeBuffer(_ format: OSType) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
    precondition(CVPixelBufferCreate(nil, width, height, format, attributes, &buffer) == kCVReturnSuccess)
    CVBufferSetAttachment(buffer!, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
    CVBufferSetAttachment(buffer!, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
    CVBufferSetAttachment(buffer!, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    return buffer!
}

func fill(_ buffer: CVPixelBuffer, videoRange: Bool) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let yo = videoRange ? 64.0 : 0.0, ys = videoRange ? 876.0 : 1023.0, cs = videoRange ? 896.0 : 1022.0
    func quantize(_ x: Double) -> UInt16 { UInt16(max(0, min(1023, x.rounded()))) << 6 }
    for plane in 0..<2 {
        let pw = CVPixelBufferGetWidthOfPlane(buffer, plane), ph = CVPixelBufferGetHeightOfPlane(buffer, plane)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt16.self)
        // Include row padding in the later exact-preservation checks.
        base.update(repeating: 0xA580, count: stride * ph)
        for y in 0..<ph {
            for x in 0..<pw {
                let rgb = patches[(y * height / ph / 8) * 8 + x * width / pw / 8]
                let luma = 0.2627 * rgb[0] + 0.678 * rgb[1] + 0.0593 * rgb[2]
                if plane == 0 { base[y * stride + x] = quantize(luma * ys + yo) }
                else {
                    base[y * stride + 2 * x] = quantize((rgb[2] - luma) / 1.8814 * cs + 512)
                    base[y * stride + 2 * x + 1] = quantize((rgb[0] - luma) / 1.4746 * cs + 512)
                }
            }
        }
    }
}

func sourceBytes(_ buffer: CVPixelBuffer) -> [Data] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    return (0..<2).map { plane in
        Data(bytes: CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!,
             count: CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
    }
}

func render(_ buffer: CVPixelBuffer, headroom: Double) throws -> [Double] {
    let frame = try pipeline.prepare(buffer)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = .renderTarget
    let texture = device.makeTexture(descriptor: descriptor)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    let command = pipeline.commandQueue.makeCommandBuffer()!
    let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
    pipeline.encode(frame, into: encoder, headroom: headroom)
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    withExtendedLifetime(frame) {}
    precondition(command.status == .completed, "GPU error: \(String(describing: command.error))")
    var pixels = [UInt16](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes {
        texture.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }
    return pixels.map { Double(Float16(bitPattern: $0)) }
}

// Independent CPU reference: reconstruct the stored YCbCr samples including
// chroma siting/interpolation, then apply the BT.2100 reference EOTF in Double.
func reference(_ buffer: CVPixelBuffer, videoRange: Bool, offset: SIMD2<Double>) -> [[Double]] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    func sample(plane: Int, u: Double, v: Double, component: Int = 0) -> Double {
        let pw = CVPixelBufferGetWidthOfPlane(buffer, plane), ph = CVPixelBufferGetHeightOfPlane(buffer, plane)
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
        let px = u * Double(pw) - 0.5, py = v * Double(ph) - 0.5
        let x = Int(floor(px)), y = Int(floor(py)), dx = px - floor(px), dy = py - floor(py)
        func at(_ x: Int, _ y: Int) -> Double {
            Double(base[min(ph - 1, max(0, y)) * stride + min(pw - 1, max(0, x)) * (plane == 0 ? 1 : 2) + component] >> 6)
        }
        return (at(x,y) * (1-dx) + at(x+1,y) * dx) * (1-dy) + (at(x,y+1) * (1-dx) + at(x+1,y+1) * dx) * dy
    }
    return (0..<width * height).map { index in
        let u = (Double(index % width) + 0.5) / Double(width), v = (Double(index / width) + 0.5) / Double(height)
        let y = (sample(plane: 0, u: u, v: v) - (videoRange ? 64 : 0)) / (videoRange ? 876 : 1023)
        let cb = (sample(plane: 1, u: u + offset.x, v: v + offset.y) - 512) / (videoRange ? 896 : 1022)
        let cr = (sample(plane: 1, u: u + offset.x, v: v + offset.y, component: 1) - 512) / (videoRange ? 896 : 1022)
        let r = y + 1.4746 * cr, b = y + 1.8814 * cb
        let scene = [r, (y - 0.2627 * r - 0.0593 * b) / 0.678, b].map { signal in
            let s = abs(signal)
            let linear = s <= 0.5 ? s*s/3 : (exp((s-0.559910729529562)/0.17883277)+0.28466892)/12
            return signal < 0 ? -linear : linear
        }
        let luminance = 0.2627 * scene[0] + 0.678 * scene[1] + 0.0593 * scene[2]
        return scene.map { $0 * pow(max(abs(luminance), 1e-12), 0.2) * referencePeak }
    }
}

var frameCount = 0, componentCount = 0
var maximumError = 0.0
for (name, format, videoRange) in formats {
    let buffer = makeBuffer(format)
    fill(buffer, videoRange: videoRange)
    let dx = (Double(width) / Double(CVPixelBufferGetWidthOfPlane(buffer, 1)) - 1) / (2 * Double(width))
    let dy = (Double(height) / Double(CVPixelBufferGetHeightOfPlane(buffer, 1)) - 1) / (2 * Double(height))
    let locations: [(CFString, SIMD2<Double>)] = [
        (kCVImageBufferChromaLocation_Center, .zero),
        (kCVImageBufferChromaLocation_Left, SIMD2(dx, 0)),
        (kCVImageBufferChromaLocation_TopLeft, SIMD2(dx, dy)),
        (kCVImageBufferChromaLocation_Top, SIMD2(0, dy)),
        (kCVImageBufferChromaLocation_BottomLeft, SIMD2(dx, -dy)),
        (kCVImageBufferChromaLocation_Bottom, SIMD2(0, -dy))
    ]
    for (location, offset) in locations {
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, location, .shouldPropagate)
        let before = sourceBytes(buffer)
        let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate)! as NSDictionary
        let expected = reference(buffer, videoRange: videoRange, offset: offset)
        var previous: [Double]?
        for headroom in [1.0, 1.25, 2.0, referencePeak, 8.0] {
            let actual = try render(buffer, headroom: headroom)
            for i in 0..<width * height {
                let peak = expected[i].max()!
                let mapped: Double
                if peak <= 1 || headroom >= referencePeak { mapped = min(peak, headroom) }
                else if headroom == 1 { mapped = 1 }
                else {
                    let k = 1 / (headroom - 1) - 1 / (referencePeak - 1)
                    mapped = min(1 + (peak - 1) / (1 + k * (peak - 1)), headroom)
                }
                for c in 0..<3 {
                    let value = expected[i][c] * (peak > 1 ? mapped / peak : 1)
                    let error = abs(actual[4*i+c] - value)
                    maximumError = max(maximumError, error)
                    precondition(error < 0.006, "\(name) \(location), headroom \(headroom), pixel \(i), channel \(c): \(actual[4*i+c]) vs \(value)")
                    if let previous, peak <= 1 {
                        precondition(actual[4*i+c] == previous[4*i+c], "SDR brightness changed with headroom")
                    }
                    precondition(actual[4*i+c] <= headroom + 0.004, "Exceeded display headroom")
                    componentCount += 1
                }
                precondition(actual[4*i+3] == 1, "Preview must be opaque")
            }
            // Peak white must actually emit EDR light when available.
            let peakWhite = actual[(4 * width + 60) * 4]
            precondition(abs(peakWhite - min(referencePeak, headroom)) < 0.006, "Lost HDR highlights")
            precondition(sourceBytes(buffer) == before, "Preview modified a source plane")
            precondition(attachments.isEqual(CVBufferCopyAttachments(buffer, .shouldPropagate)), "Preview changed source metadata")
            previous = actual
            frameCount += 1
        }
    }
    CVBufferRemoveAttachment(buffer, kCVImageBufferTransferFunctionKey)
    do { _ = try pipeline.prepare(buffer); fatalError("Accepted a frame without HLG metadata") }
    catch OutputPreviewError.unsupportedFrame {}
    print("PASS \(name): colors, chroma siting, orientation, SDR/HDR headroom, source preservation")
}
let sdr = makeBuffer(kCVPixelFormatType_32BGRA)
do { _ = try pipeline.prepare(sdr); fatalError("Accepted an unsupported pixel format") }
catch OutputPreviewError.unsupportedFrame {}
print("PASS \(frameCount) GPU frames, \(componentCount) RGB comparisons; maximum linear EDR error \(maximumError)")
