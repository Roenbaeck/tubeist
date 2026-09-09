import CoreVideo
import Foundation
import Metal

enum OutputPreviewError: LocalizedError {
    case unavailable
    case unsupportedFrame
    case texture(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Output preview is unavailable."
        case .unsupportedFrame: "Output preview requires a 10-bit HLG/BT.2020 frame."
        case .texture(let status): "Could not read the output frame (\(status))."
        }
    }
}

// Keep the layout in sync with OutputPreviewArguments in Kernels.metal.
struct OutputPreviewArguments {
    var lumaOffset: Float
    var lumaRange: Float
    var chromaRange: Float
    var headroom: Float = 1
    var chromaOffset: SIMD2<Float> = .zero

    init(pixelBuffer: CVPixelBuffer) throws {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
            lumaOffset = 64; lumaRange = 876; chromaRange = 896
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            lumaOffset = 0; lumaRange = 1023; chromaRange = 1022
        default:
            throw OutputPreviewError.unsupportedFrame
        }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
              CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil) as? String == kCVImageBufferColorPrimaries_ITU_R_2020 as String,
              CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
              CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String else {
            throw OutputPreviewError.unsupportedFrame
        }

        // Normalized texture sampling assumes centered chroma. Compensate for
        // the camera's declared siting before interpolating its chroma plane.
        let width = Float(CVPixelBufferGetWidthOfPlane(pixelBuffer, 0))
        let height = Float(CVPixelBufferGetHeightOfPlane(pixelBuffer, 0))
        let chromaWidth = Float(CVPixelBufferGetWidthOfPlane(pixelBuffer, 1))
        let chromaHeight = Float(CVPixelBufferGetHeightOfPlane(pixelBuffer, 1))
        guard min(width, height, chromaWidth, chromaHeight) > 0 else {
            throw OutputPreviewError.unsupportedFrame
        }
        let dx = (width / chromaWidth - 1) / (2 * width)
        let dy = (height / chromaHeight - 1) / (2 * height)
        let location = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferChromaLocationTopFieldKey, nil) as? String
        if location == kCVImageBufferChromaLocation_Left as String {
            chromaOffset = SIMD2(dx, 0)
        } else if location == kCVImageBufferChromaLocation_TopLeft as String {
            chromaOffset = SIMD2(dx, dy)
        } else if location == kCVImageBufferChromaLocation_Top as String {
            chromaOffset = SIMD2(0, dy)
        } else if location == kCVImageBufferChromaLocation_BottomLeft as String {
            chromaOffset = SIMD2(dx, -dy)
        } else if location == kCVImageBufferChromaLocation_Bottom as String {
            chromaOffset = SIMD2(0, -dy)
        }
    }
}

// Retain the source and its texture views until the GPU finishes reading them.
// These immutable references are shared only for read-only preview rendering.
final class MetalOutputFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let luma: CVMetalTexture
    let chroma: CVMetalTexture
    let arguments: OutputPreviewArguments

    init(pixelBuffer: CVPixelBuffer, luma: CVMetalTexture, chroma: CVMetalTexture, arguments: OutputPreviewArguments) {
        self.pixelBuffer = pixelBuffer
        self.luma = luma
        self.chroma = chroma
        self.arguments = arguments
    }
}

final class MetalOutputPipeline {
    static let pixelFormat: MTLPixelFormat = .rgba16Float
    static let referenceHeadroom: CGFloat = 1000 / 203
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache

    init(device: MTLDevice, library: MTLLibrary? = nil) throws {
        self.device = device
        guard let queue = device.makeCommandQueue(),
              let library = library ?? device.makeDefaultLibrary() else {
            throw OutputPreviewError.unavailable
        }
        commandQueue = queue
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "outputPreviewVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "outputPreviewFragment")
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { throw OutputPreviewError.texture(status) }
        textureCache = cache
    }

    func prepare(_ pixelBuffer: CVPixelBuffer) throws -> MetalOutputFrame {
        let arguments = try OutputPreviewArguments(pixelBuffer: pixelBuffer)
        func texture(plane: Int, format: MTLPixelFormat) throws -> CVMetalTexture {
            var texture: CVMetalTexture?
            let attributes = [kCVMetalTextureUsage: MTLTextureUsage.shaderRead.rawValue] as CFDictionary
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, pixelBuffer, attributes, format,
                CVPixelBufferGetWidthOfPlane(pixelBuffer, plane),
                CVPixelBufferGetHeightOfPlane(pixelBuffer, plane), plane, &texture
            )
            guard status == kCVReturnSuccess, let texture, CVMetalTextureGetTexture(texture) != nil else {
                throw OutputPreviewError.texture(status)
            }
            return texture
        }
        return try MetalOutputFrame(
            pixelBuffer: pixelBuffer, luma: texture(plane: 0, format: .r16Unorm),
            chroma: texture(plane: 1, format: .rg16Unorm), arguments: arguments
        )
    }

    func encode(_ frame: MetalOutputFrame, into encoder: MTLRenderCommandEncoder, headroom: CGFloat) {
        var arguments = frame.arguments
        arguments.headroom = Float(headroom.isFinite ? max(1, headroom) : 1)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(frame.luma), index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(frame.chroma), index: 1)
        encoder.setFragmentBytes(&arguments, length: MemoryLayout<OutputPreviewArguments>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
