import Foundation
import Metal

struct Arguments {
    var strength: Float = 1
    var frame: UInt32 = 137
    var threadgroupWidth: UInt32 = 32
    var threadgroupHeight: UInt32 = 32
    var widthRatio: UInt32 = 2
    var heightRatio: UInt32 = 2
}
let root = CommandLine.arguments[1]
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let original = try String(contentsOfFile: root + "/Tools/StyleEffectProbe/Reference.metal", encoding: .utf8)
// The old VHS kernel has data races. For a deterministic math reference, read
// the original pixels and select the top-left luma thread as the chroma owner.
// Keep the original (including otherwise wasted math) separately for timing.
let referenceSource = original
    .replacingOccurrences(of: "kernel void vhs(", with: "kernel void referenceVHS(")
    .replacingOccurrences(of: "uint2 gid [[thread_position_in_grid]]) {\n\n    // Get texture dimensions", with: "texture2d<float, access::read> sourceY [[texture(2)]],\ntexture2d<float, access::read> sourceCbCr [[texture(3)]],\nuint2 gid [[thread_position_in_grid]]) {\n\n    // Get texture dimensions")
    .replacingOccurrences(of: "ySample = yTexture.read", with: "ySample = sourceY.read")
    .replacingOccurrences(of: "cbcrTexture.read(uint2(cbGid_cbcr))", with: "sourceCbCr.read(uint2(cbGid_cbcr))")
    .replacingOccurrences(of: "cbcrTexture.read(uint2(crGid_cbcr))", with: "sourceCbCr.read(uint2(crGid_cbcr))")
    .replacingOccurrences(of: "// --- Apply effects to CbCr texture ---", with: "if (gid.x % args.widthRatio != 0 || gid.y % args.heightRatio != 0) { return; }\n// --- Apply effects to CbCr texture ---")
    .replacingOccurrences(of: "uint2 cbGid_cbcr = distortedGidCbCr + uint2(", with: "int2 cbGid_cbcr = int2(distortedGidCbCr) + int2(")
    .replacingOccurrences(of: "uint2 crGid_cbcr = distortedGidCbCr - uint2(", with: "int2 crGid_cbcr = int2(distortedGidCbCr) - int2(")
let current = try device.makeLibrary(source: String(contentsOfFile: root + "/Tubeist/Kernels.metal", encoding: .utf8), options: nil)
let legacy = try device.makeLibrary(source: original, options: nil)
let reference = try device.makeLibrary(source: referenceSource, options: nil)
func pipeline(_ library: MTLLibrary, _ name: String) throws -> MTLComputePipelineState {
    try device.makeComputePipelineState(function: library.makeFunction(name: name)!)
}
let optimized = try ["vhs": pipeline(current, "vhs"), "grain": pipeline(current, "grain")]
let old = try ["vhs": pipeline(legacy, "vhs"), "grain": pipeline(legacy, "grain")]
let expected = try ["vhs": pipeline(reference, "referenceVHS"), "grain": pipeline(reference, "grain")]
func texture(_ width: Int, _ height: Int, chroma: Bool = false) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: chroma ? .rg16Unorm : .r16Unorm,
        width: width, height: height, mipmapped: false)
    d.storageMode = .shared
    d.usage = [.shaderRead, .shaderWrite]
    return device.makeTexture(descriptor: d)!
}
func codes(_ texture: MTLTexture) -> [UInt16] {
    let components = texture.pixelFormat == .rg16Unorm ? 2 : 1
    var result = [UInt16](repeating: 0, count: texture.width * texture.height * components)
    result.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * components * 2,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }
    return result
}
func fill(_ texture: MTLTexture) {
    let count = texture.width * texture.height * (texture.pixelFormat == .rg16Unorm ? 2 : 1)
    // Deterministic, spatially varying 10-bit values, including near-black/white.
    let values = (0..<count).map { UInt16((($0 * 37 + $0 / 113) % 1024) << 6) }
    values.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: count / texture.height * 2) }
}
final class Fixture {
    let y, uv, outputY, outputUV, snapshotY, snapshotUV: MTLTexture
    init(_ width: Int, _ height: Int, verticalRatio: Int = 2) {
        y = texture(width, height); uv = texture(width / 2, height / verticalRatio, chroma: true)
        outputY = texture(width, height); outputUV = texture(width / 2, height / verticalRatio, chroma: true)
        snapshotY = texture(width, height); snapshotUV = texture(width / 2, height / verticalRatio, chroma: true)
        fill(y); fill(uv)
    }
    func run(_ names: [String], mode: String, frame: UInt32 = 137, strength: Float = 1) -> Double {
        var args = Arguments(strength: strength, frame: frame, heightRatio: UInt32(y.height / uv.height))
        let command = queue.makeCommandBuffer()!
        let blit = command.makeBlitCommandEncoder()!
        blit.copy(from: y, to: outputY); blit.copy(from: uv, to: outputUV)
        if names.contains("vhs") && mode != "legacy" {
            blit.copy(from: outputY, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: y.width, height: mode.hasPrefix("optimized") ? Int(ceil(Float(y.height) * 0.05)) : y.height, depth: 1),
                to: snapshotY, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.copy(from: outputUV, to: snapshotUV)
        }
        blit.endEncoding()
        let encoder = command.makeComputeCommandEncoder()!
        encoder.setTexture(outputY, index: 0); encoder.setTexture(outputUV, index: 1)
        encoder.setTexture(snapshotY, index: 2); encoder.setTexture(snapshotUV, index: 3)
        encoder.setBytes(&args, length: MemoryLayout<Arguments>.stride, index: 0)
        for name in names {
            let p = (mode.hasPrefix("optimized") ? optimized : mode == "legacy" ? old : expected)[name]!
            let groupHeight = name == "grain" && mode.hasPrefix("optimized-") ? Int(mode.split(separator: "-").last!)! : 32
            encoder.setComputePipelineState(p)
            precondition(p.maxTotalThreadsPerThreadgroup >= 1024)
            encoder.dispatchThreads(MTLSize(width: y.width, height: y.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 32, height: groupHeight, depth: 1))
            encoder.memoryBarrier(scope: .textures)
        }
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        precondition(command.status == .completed, "Metal failed: \(String(describing: command.error))")
        return (command.gpuEndTime - command.gpuStartTime) * 1000
    }
}
print("GPU: \(device.name)")
var worstDifference = 0
for (width, height, ratio) in [(320, 180, 2), (322, 182, 2), (320, 180, 1), (3840, 2160, 2)] {
    let f = Fixture(width, height, verticalRatio: ratio)
    let frames: [UInt32] = width > 1000 ? [137, 599] : [0, 1, 137, 299, 599]
    for frame in frames {
        for strength: Float in [-1, 0, 0.5, 1] {
            for names in [["grain"], ["vhs"], ["vhs", "grain"]] {
                _ = f.run(names, mode: "reference", frame: frame, strength: strength)
                let y = codes(f.outputY), uv = codes(f.outputUV)
                _ = f.run(names, mode: "optimized", frame: frame, strength: strength)
                let actualY = codes(f.outputY), actualUV = codes(f.outputUV)
                let maximum = zip(y + uv, actualY + actualUV).map { abs(Int($0) - Int($1)) }.max()!
                worstDifference = max(worstDifference, maximum)
                precondition(maximum <= 64, "Output difference \(maximum) for \(names), \(width)x\(height), \(ratio), frame \(frame), strength \(strength)")
            }
        }
    }
    print("PASS output comparison: \(width)x\(height), chroma vertical ratio \(ratio)")
}
print("Largest 16-bit code difference: \(worstDifference) (64 codes = one 10-bit step)")
let benchmark = Fixture(3840, 2160)
for names in [["grain"], ["vhs"], ["vhs", "grain"]] {
    let modes = ["legacy", "optimized", "optimized-8", "optimized-16"]
    var timings = Dictionary(uniqueKeysWithValues: modes.map { ($0, [Double]()) })
    for iteration in 0..<64 {
        for mode in iteration.isMultiple(of: 2) ? modes : modes.reversed() {
            let ms = benchmark.run(names, mode: mode, frame: UInt32((iteration * 23) % 600))
            if iteration >= 20 { timings[mode]!.append(ms) }
        }
    }
    let before = timings["legacy"]!.sorted()[22]
    for mode in modes {
        let after = timings[mode]!.sorted()[22]
        print(String(format: "%@ %@: %.3f ms, %.1f%% reduction", names.joined(separator: " + "), mode, after, 100 * (1 - after / before)))
    }
}
