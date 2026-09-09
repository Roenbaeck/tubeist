// Compiled with the production ImprintArguments.swift by validate.sh.
import Foundation
import CoreImage
import CoreVideo
import Metal

let formats: [(String, OSType)] = [
    ("420-full", kCVPixelFormatType_420YpCbCr10BiPlanarFullRange),
    ("420-video", kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
    ("422-full", kCVPixelFormatType_422YpCbCr10BiPlanarFullRange),
    ("422-video", kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange),
]
let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let context = CIContext(mtlDevice: device, options: [.workingColorSpace: hlg])
let library = try device.makeLibrary(source: String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8), options: nil)
let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "imprint")!)
var cache: CVMetalTextureCache?
precondition(CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess)

func patch(_ rgb: [Float], alpha: Float = 1) -> CIImage {
    let rgba = [rgb[0] * alpha, rgb[1] * alpha, rgb[2] * alpha, alpha]
    let data = rgba.withUnsafeBytes { Data($0) }
    return CIImage(bitmapData: data, bytesPerRow: 16, size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: srgb)
        .clampedToExtent()
}

func makeBuffer(format: OSType, bounds: CGRect) -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
    precondition(CVPixelBufferCreate(nil, Int(bounds.width), Int(bounds.height), format, attributes, &result) == kCVReturnSuccess)
    let buffer = result!
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    return buffer
}

func render(_ source: CIImage, over background: CIImage, format: OSType) -> (CVPixelBuffer, CVPixelBuffer) {
    let bounds = source.extent
    let width = Int(bounds.width), height = Int(bounds.height)
    let actual = makeBuffer(format: format, bounds: bounds)
    let reference = makeBuffer(format: format, bounds: bounds)
    context.render(background, to: actual, bounds: bounds, colorSpace: hlg)
    // Independent reference: Core Image does both source-over and RGB-to-YCbCr.
    context.render(source.composited(over: background), to: reference, bounds: bounds, colorSpace: hlg)

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    let texture = device.makeTexture(descriptor: descriptor)!
    let command = queue.makeCommandBuffer()!
    let flip = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(height))
    context.render(source.transformed(by: flip), to: texture, commandBuffer: command, bounds: bounds, colorSpace: hlg)

    let uvWidth = CVPixelBufferGetWidthOfPlane(actual, 1)
    let uvHeight = CVPixelBufferGetHeightOfPlane(actual, 1)
    var yRef: CVMetalTexture?, uvRef: CVMetalTexture?
    precondition(CVMetalTextureCacheCreateTextureFromImage(nil, cache!, actual, nil, .r16Unorm, width, height, 0, &yRef) == kCVReturnSuccess)
    precondition(CVMetalTextureCacheCreateTextureFromImage(nil, cache!, actual, nil, .rg16Unorm, uvWidth, uvHeight, 1, &uvRef) == kCVReturnSuccess)
    let encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(CVMetalTextureGetTexture(yRef!), index: 0)
    encoder.setTexture(CVMetalTextureGetTexture(uvRef!), index: 1)
    encoder.setTexture(texture, index: 2)
    var args = ImprintArguments()
    args.widthRatio = UInt32(width / uvWidth)
    args.heightRatio = UInt32(height / uvHeight)
    args.setPixelFormat(format)
    encoder.setBytes(&args, length: MemoryLayout<ImprintArguments>.size, index: 0)
    encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    precondition(command.status == .completed, "Metal imprint failed: \(String(describing: command.error))")
    return (actual, reference)
}

func codes(_ buffer: CVPixelBuffer, plane: Int) -> [UInt16] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let components = plane == 0 ? 1 : 2
    let width = CVPixelBufferGetWidthOfPlane(buffer, plane) * components
    let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / MemoryLayout<UInt16>.stride
    let address = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt16.self)
    return (0..<height).flatMap { row in (0..<width).map { address[row * stride + $0] } }
}

let bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
var cases: [(String, [Float], Float)] = [0, 0.05, 0.1, 0.2, 0.4, 0.5, 0.6, 0.8, 0.9, 0.95, 1].map {
    ("gray \($0)", [Float($0), Float($0), Float($0)], Float(1))
}
cases += [("red", [1, 0, 0], 1), ("green", [0, 1, 0], 1), ("blue", [0, 0, 1], 1)]
for n in 0..<200 {
    cases.append(("color \(n)", [Float((n * 73) % 251) / 250, Float((n * 109) % 251) / 250, Float((n * 163) % 251) / 250], [Float(0), 0.25, 0.5, 0.75, 1][n % 5]))
}
for (name, format) in formats {
    var maxError = 0
    for (label, rgb, alpha) in cases {
        let source = patch(rgb, alpha: alpha).cropped(to: bounds)
        let background = patch([0.18, 0.35, 0.6]).cropped(to: bounds)
        let (actual, reference) = render(source, over: background, format: format)
        for plane in 0...1 {
            let actualCodes = codes(actual, plane: plane)
            let referenceCodes = codes(reference, plane: plane)
            // A nonzero reference catches unavailable/denied GPU rendering.
            if plane == 1 {
                precondition(referenceCodes.contains { $0 > 0 }, "Core Image rendered an empty reference")
            }
            precondition(actualCodes.allSatisfy { $0 & 63 == 0 }, "Output contains fractional ten-bit codes")
            let error = zip(actualCodes, referenceCodes).map { abs(Int($0 >> 6) - Int($1 >> 6)) }.max()!
            maxError = max(maxError, error)
            precondition(error <= 1, "\(name), \(label), alpha \(alpha), plane \(plane): error \(error) exceeds one ten-bit code")
            if alpha == 0 {
                precondition(actualCodes == referenceCodes, "Transparent overlay altered the background")
            }
        }
    }
    print("PASS \(name): \(cases.count) opaque/transparent patches; maximum error \(maxError)/1023")
}

// Optional local images exercise orientation and the entire luma plane. Chroma
// edges are excluded: Core Image resamples chroma; imprint samples one texel.
for path in CommandLine.arguments.dropFirst(2) {
    let input = CIImage(contentsOf: URL(fileURLWithPath: path))!
    let bounds = CGRect(x: 0, y: 0, width: Int(input.extent.width) / 2 * 2, height: Int(input.extent.height) / 2 * 2)
    let source = input.cropped(to: bounds)
    for (name, format) in formats {
        let (actual, reference) = render(source, over: patch([0.18, 0.18, 0.18]).cropped(to: bounds), format: format)
        let differences = zip(codes(actual, plane: 0), codes(reference, plane: 0)).map { abs(Int($0 >> 6) - Int($1 >> 6)) }
        let maximum = differences.max()!
        let mean = Double(differences.reduce(0, +)) / Double(differences.count)
        precondition(maximum <= 2 && mean < 0.1, "\(path) \(name): luma mismatch; max \(maximum), mean \(mean)")
        print("PASS \(URL(fileURLWithPath: path).lastPathComponent) \(name): luma max \(maximum)/1023, mean \(String(format: "%.5f", mean))/1023")
    }
}
