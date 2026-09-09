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

func render(_ source: CIImage, over background: CIImage, format: OSType, regions: [CGRect]? = nil) -> (CVPixelBuffer, CVPixelBuffer) {
    let bounds = source.extent
    let width = Int(bounds.width), height = Int(bounds.height)
    let actual = makeBuffer(format: format, bounds: bounds)
    let reference = makeBuffer(format: format, bounds: bounds)
    context.render(background, to: actual, bounds: bounds, colorSpace: hlg)
    // Seed the independent reference with exactly the same camera samples.
    context.render(background, to: reference, bounds: bounds, colorSpace: hlg)

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    descriptor.storageMode = .shared
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
    for region in regions ?? [bounds] {
        args.offsetX = UInt32(region.minX); args.offsetY = UInt32(region.minY)
        encoder.setBytes(&args, length: MemoryLayout<ImprintArguments>.size, index: 0)
        encoder.dispatchThreads(MTLSize(width: Int(region.width), height: Int(region.height), depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    }
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    precondition(command.status == .completed, "Metal imprint failed: \(String(describing: command.error))")
    var overlay = [UInt16](repeating: 0, count: width * height * 4)
    overlay.withUnsafeMutableBytes {
        texture.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }
    composeReference(overlay: overlay, into: reference, format: format)
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

// Independent Double-precision HLG/extended-sRGB compositing reference. Unlike the GPU block loop,
// calculate a full-resolution result first, then reduce chroma in a second pass.
// Work from the quantized inputs so this measures blending, not input conversion.
func composeReference(overlay: [UInt16], into buffer: CVPixelBuffer, format: OSType) {
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let uvWidth = CVPixelBufferGetWidthOfPlane(buffer, 1), uvHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
    let rx = width / uvWidth, ry = height / uvHeight
    var args = ImprintArguments(); args.setPixelFormat(format)
    let ys = args.videoRange == 1 ? 876.0 : 1023.0
    let yo = args.videoRange == 1 ? 64.0 : 0.0
    let cs = args.videoRange == 1 ? 896.0 : 1022.0
    let originalY = codes(buffer, plane: 0), originalUV = codes(buffer, plane: 1)
    var resultY = originalY
    var cbDelta = [Double](repeating: 0, count: width * height)
    var crDelta = cbDelta
    let weights = [0.2627, 0.6780, 0.0593]
    func signed(_ x: Double, _ result: Double) -> Double { x < 0 ? -result : result }
    func decode(_ rgb: [Double]) -> [Double] {
        let scene = rgb.map { x -> Double in
            let v = abs(x)
            return signed(x, v <= 0.5 ? v*v/3 : (exp((v-0.559910729529562)/0.17883277)+0.28466892)/12)
        }
        let luminance = zip(scene, weights).map(*).reduce(0, +)
        let light = scene.map { $0 * pow(max(abs(luminance), 1e-12), 0.2) * 1000 / 203 }
        let matrix = [[1.660491002, -0.587641139, -0.072849863], [-0.124550475, 1.132899897, -0.008349423], [-0.018150763, -0.100578898, 1.118729661]]
        return matrix.map { row in
            let x = zip(row, light).map(*).reduce(0,+)
            let v = abs(x)
            return signed(x, v <= 0.0031308 ? 12.92*v : 1.055*pow(v,1/2.4)-0.055)
        }
    }
    func encode(_ webRGB: [Double]) -> [Double] {
        let srgb = webRGB.map { x in
            let v = abs(x)
            return signed(x, v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4))
        }
        let matrix = [[0.627403896, 0.329283038, 0.043313066], [0.069097289, 0.919540395, 0.011362316], [0.016391439, 0.088013308, 0.895595253]]
        let light = matrix.map { zip($0,srgb).map(*).reduce(0,+)*203/1000 }
        let luminance = zip(light, weights).map(*).reduce(0, +)
        let scale = pow(max(abs(luminance), 1e-12), -1.0/6.0)
        return light.map { x in
            let v = abs(x * scale)
            return signed(x, v <= 1.0/12.0 ? sqrt(3*v) : 0.17883277*log(12*v-0.28466892)+0.559910729529562)
        }
    }
    func quantize(_ x: Double) -> UInt16 { UInt16(max(0, min(1023, x.rounded()))) << 6 }
    for i in 0..<(width * height) {
        let alpha = Double(overlay[i*4+3]) / 65535
        if alpha == 0 { continue }
        let uv = ((i / width / ry) * uvWidth + (i % width / rx)) * 2
        let cb = (Double(originalUV[uv] >> 6) - 512) / cs
        let cr = (Double(originalUV[uv+1] >> 6) - 512) / cs
        var rgb = (0..<3).map { Double(overlay[i*4+$0]) / 65535 / alpha }
        if alpha < 1 {
            let y = (Double(originalY[i] >> 6) - yo) / ys
            let r = y + 1.4746*cr, b = y + 1.8814*cb
            let background = decode([r, (y-0.2627*r-0.0593*b)/0.678, b])
            let foreground = decode(rgb)
            rgb = encode(zip(foreground, background).map { alpha*$0 + (1-alpha)*$1 })
        }
        let y = zip(rgb, weights).map(*).reduce(0,+)
        resultY[i] = quantize(y*ys+yo)
        cbDelta[i] = (rgb[2]-y)/1.8814 - cb
        crDelta[i] = (rgb[0]-y)/1.4746 - cr
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt16.self)
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
    for row in 0..<height {
        for x in 0..<width { yBase[row*yStride+x] = resultY[row*width+x] }
    }
    let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt16.self)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
    for row in 0..<uvHeight {
        for x in 0..<uvWidth {
            var cb = 0.0, cr = 0.0
            for dy in 0..<ry {
                for dx in 0..<rx {
                    let i = (row*ry+dy)*width+x*rx+dx
                    cb += cbDelta[i]; cr += crDelta[i]
                }
            }
            let index = (row*uvWidth+x)*2
            uvBase[row*uvStride+x*2] = quantize(Double(originalUV[index] >> 6)+cb*cs/Double(rx*ry))
            uvBase[row*uvStride+x*2+1] = quantize(Double(originalUV[index+1] >> 6)+cr*cs/Double(rx*ry))
        }
    }
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

// Exercise varying luma/alpha inside shared chroma cells, transparent cells,
// odd region edges, overlapping boxes, and deterministic in-place execution.
let boxes = [CGRect(x: 3, y: 5, width: 16, height: 12), CGRect(x: 11, y: 9, width: 16, height: 12)]
let regions = ImprintArguments.regions(bounds: bounds, boundingBoxes: boxes, coverage: 0.4)
precondition(regions == [CGRect(x: 2, y: 4, width: 26, height: 18)])
precondition(ImprintArguments.regions(bounds: bounds, boundingBoxes: [], coverage: 0) == [bounds])
precondition(ImprintArguments.regions(bounds: bounds, boundingBoxes: [CGRect(x: 40, y: 40, width: 2, height: 2)], coverage: 0).isEmpty)
func patternedImage(overlay: Bool) -> CIImage {
    var rgba: [Float] = []
    for y in 0..<32 {
        for x in 0..<32 {
            let covered = boxes.contains { $0.contains(CGPoint(x: x, y: y)) }
            let alpha: Float = overlay ? (covered ? [0, 0.25, 0.75, 1][(x+2*y)%4] : 0) : 1
            let rgb: [Float] = overlay ? [Float(x%7)/6, Float(y%5)/4, 0.6] : [Float((x+3*y)%13)/12, 0.3, 0.7]
            rgba += rgb.map { $0*alpha } + [alpha]
        }
    }
    // Match the pixel-space rectangle coordinates used by dispatch.
    return rgba.withUnsafeBytes { CIImage(bitmapData: Data($0), bytesPerRow: 32*16, size: CGSize(width: 32, height: 32), format: .RGBAf, colorSpace: srgb) }
}
for (name, format) in formats {
    var previous: [[UInt16]]?
    for _ in 0..<3 {
        let (actual, reference) = render(patternedImage(overlay: true), over: patternedImage(overlay: false), format: format, regions: regions)
        let output = (0...1).map { codes(actual, plane: $0) }
        for plane in 0...1 {
            let expected = codes(reference, plane: plane)
            let maximum = zip(output[plane], expected).map { abs(Int($0 >> 6)-Int($1 >> 6)) }.max()!
            precondition(maximum <= 1, "\(name) mixed alpha, plane \(plane): \(maximum)")
        }
        if let previous { precondition(output == previous, "In-place blending is nondeterministic") }
        previous = output
    }
    print("PASS \(name): mixed alpha/chroma cells and overlapping regions, three identical runs")
}

// Closed-form neutral check independent of the general RGB oracle: half-
// opaque black halves the extended-sRGB code value, including above-white HDR.
func hlgGray(_ value: Float) -> CIImage {
    let rgba: [Float] = [value, value, value, 1]
    return rgba.withUnsafeBytes { CIImage(bitmapData: Data($0), bytesPerRow: 16, size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: hlg) }.clampedToExtent().cropped(to: bounds)
}
func webValue(_ value: Double) -> Double {
    let scene = value <= 0.5 ? value*value/3 : (exp((value-0.559910729529562)/0.17883277)+0.28466892)/12
    let light = pow(scene, 1.2)*1000/203
    return light <= 0.0031308 ? 12.92*light : 1.055*pow(light, 1/2.4)-0.055
}
for (name, format) in formats {
    var args = ImprintArguments(); args.setPixelFormat(format)
    let scale = args.videoRange == 1 ? 876.0 : 1023.0
    let offset = args.videoRange == 1 ? 64.0 : 0.0
    for level: Float in [0.75, 0.875, 1] {
        let background = hlgGray(level)
        let (untouched, _) = render(patch([0,0,0], alpha: 0).cropped(to: bounds), over: background, format: format)
        let (actual, reference) = render(patch([0,0,0], alpha: 0.5).cropped(to: bounds), over: background, format: format)
        let before = (Double(codes(untouched, plane: 0)[0] >> 6)-offset)/scale
        let after = (Double(codes(actual, plane: 0)[0] >> 6)-offset)/scale
        precondition(abs(webValue(after)/webValue(before)-0.5) < 0.006, "Half-opacity black must halve the web code value")
        for plane in 0...1 {
            let maximum = zip(codes(actual, plane: plane), codes(reference, plane: plane)).map { abs(Int($0 >> 6)-Int($1 >> 6)) }.max()!
            precondition(maximum <= 1, "\(name) HDR \(level) mismatch")
        }
    }
    print("PASS \(name): half-opacity black halves the web value at reference white and two HDR levels")
}

// Optional local images check both complete planes against the Double reference.
for path in CommandLine.arguments.dropFirst(2) {
    let input = CIImage(contentsOf: URL(fileURLWithPath: path))!
    let bounds = CGRect(x: 0, y: 0, width: Int(input.extent.width) / 2 * 2, height: Int(input.extent.height) / 2 * 2)
    let source = input.cropped(to: bounds)
    for (name, format) in formats {
        let (actual, reference) = render(source, over: patch([0.18, 0.18, 0.18]).cropped(to: bounds), format: format)
        for plane in 0...1 {
            let differences = zip(codes(actual, plane: plane), codes(reference, plane: plane)).map { abs(Int($0 >> 6) - Int($1 >> 6)) }
            let maximum = differences.max()!
            let mean = Double(differences.reduce(0, +)) / Double(differences.count)
            precondition(maximum <= 1 && mean < 0.01, "\(path) \(name), plane \(plane): max \(maximum), mean \(mean)")
            print("PASS \(URL(fileURLWithPath: path).lastPathComponent) \(name), plane \(plane): max \(maximum)/1023, mean \(String(format: "%.5f", mean))/1023")
        }
    }
}
