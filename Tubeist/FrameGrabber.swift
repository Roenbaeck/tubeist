//
//  FrameGrabber.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-05.
//

import AVFoundation
import CoreImage
import Metal

// this is not 1-1 with the Metal struct, since textures are set differently
struct KernelArguments {
    var strength: Float = 0
    var frame: UInt32 = 0
    var threadgroupWidth: UInt32 = 0
    var threadgroupHeight: UInt32 = 0
    var widthRatio: UInt32 = 1
    var heightRatio: UInt32 = 1
}

struct KernelSettings {
    var pipeline: MTLComputePipelineState
    var threads: MTLSize
    var args: MTLBuffer // of type KernelArguments
}

struct ImprintArguments {
    var offsetX: UInt32 = 0
    var offsetY: UInt32 = 0
    var widthRatio: UInt32 = 1
    var heightRatio: UInt32 = 1
}

private actor FrameTinkerer {
    // frame grabbing settings
    private var grabbingFrames: Bool = false
    private var style: String?
    private var styleStrength: Float = 1.0
    private var effect: String?
    private var effectStrength: Float = 1.0

    // metal stuff
    private let context: CIContext
    private var metalDevice: MTLDevice?
    private var library: MTLLibrary?
    private var commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var kernels: [String: KernelSettings] = [:]
    private var lumaTexture: CVMetalTexture?
    private var chromaTexture: CVMetalTexture?

    // overlay imprinting
    private var overlayTexture: MTLTexture?
    private var imprintPipeline: MTLComputePipelineState?
    private var boundingBoxData: [(MTLBuffer, MTLSize, MTLSize)] = []
    
    // resettable
    private var measureTextures: Bool = true
    private var lumaWidth: Int = DEFAULT_CAPTURE_WIDTH
    private var lumaHeight: Int = DEFAULT_CAPTURE_HEIGHT
    private var chromaWidth: Int = DEFAULT_CAPTURE_WIDTH
    private var chromaHeight: Int = DEFAULT_CAPTURE_HEIGHT
    private var lumaChromaWidthRatio: UInt32 = 1
    private var lumaChromaHeightRatio: UInt32 = 1
    private var currentSampleBuffer: CMSampleBuffer?
    private var frameNumber: UInt32 = 0
    private var threadsPerGrid: MTLSize = MTLSize(
        width: DEFAULT_CAPTURE_WIDTH,
        height: DEFAULT_CAPTURE_HEIGHT,
        depth: 1
    )

    func start() {
        grabbingFrames = true
    }
    func stop() {
        grabbingFrames = false
    }
    func isActive() -> Bool {
        grabbingFrames
    }
    func refreshStyle() {
        style = Settings.style
    }
    func getStyle() -> String? {
        style
    }
    func setStyleStrength(_ strength: Float) {
        self.styleStrength = strength
    }
    func getStyleStrength() -> Float {
        styleStrength
    }
    func refreshEffect() {
        effect = Settings.effect
    }
    func getEffect() -> String? {
        effect
    }
    func setEffectStrength(_ strength: Float) {
        self.effectStrength = strength
    }
    func getEffectStrength() -> Float {
        effectStrength
    }
    
    init() {
        guard let metalDevice = MTLCreateSystemDefaultDevice(),
              let commandQueue = metalDevice.makeCommandQueue() else {
            context = CIContext(
                options: [
                    .useSoftwareRenderer: true,
                    .workingColorSpace: CG_COLOR_SPACE,
                    .cacheIntermediates: true
                ])
            LOG("Created rendering context without Metal support", level: .warning)
            return
        }
        context = CIContext(
            mtlDevice: metalDevice,
            options: [
                .useSoftwareRenderer: false,
                .workingColorSpace: CG_COLOR_SPACE,
                .cacheIntermediates: true,
                .memoryTarget: 512
            ])
        LOG("Created rendering context with Metal support", level: .info)
        commandQueue.label = "FrameTinkerer"
        self.metalDevice = metalDevice
        self.commandQueue = commandQueue
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            metalDevice,
            nil,
            &textureCache
        )
        self.textureCache = textureCache
        library = metalDevice.makeDefaultLibrary()

        var kernelNames = AVAILABLE_STYLES.filter( { $0 != NO_STYLE } )
        kernelNames.append(contentsOf: AVAILABLE_EFFECTS.filter( { $0 != NO_EFFECT } ))
                                                   
        for kernel in kernelNames {
            guard let function = library?.makeFunction(name: kernel.lowercased()) else {
                LOG("Could not make function out of kernel code '\(kernel)'", level: .error)
                return
            }
            do {
                let pipeline = try metalDevice.makeComputePipelineState(function: function)
                // calculating optimum threadgroup and grid sizes
                let w = pipeline.threadExecutionWidth
                let h = pipeline.maxTotalThreadsPerThreadgroup / w
                let threads = MTLSize(width: w, height: h, depth: 1)
                
                var kernelArguments = KernelArguments()
                kernelArguments.threadgroupWidth = UInt32(w)
                kernelArguments.threadgroupHeight = UInt32(h)
                kernelArguments.widthRatio = lumaChromaWidthRatio
                kernelArguments.heightRatio = lumaChromaHeightRatio
                
                guard let kernelArgumentBuffer = metalDevice.makeBuffer(
                    bytes: &kernelArguments,
                    length: MemoryLayout<KernelArguments>.size,
                    options: [.cpuCacheModeWriteCombined]
                )
                else {
                    LOG("Could not create kernel argument buffer", level: .error)
                    return
                }

                kernels[kernel] = KernelSettings(
                    pipeline: pipeline,
                    threads: threads,
                    args: kernelArgumentBuffer
                )
            }
            catch {
                LOG("Failed to create pipeline state for kernels: \(error)", level: .error)
                return
            }
            guard let function = library?.makeFunction(name: "imprint") else {
                LOG("Could not make function out of imprint kernel", level: .error)
                return
            }
            do {
                imprintPipeline = try metalDevice.makeComputePipelineState(function: function)
            } catch {
                LOG("Failed to create pipeline state: \(error)", level: .error)
            }
        }
    }
    
    func reset() {
        measureTextures = true
        currentSampleBuffer = nil
        frameNumber = 0
        var width = DEFAULT_CAPTURE_WIDTH
        var height = DEFAULT_CAPTURE_HEIGHT
        if Settings.isInputSyncedWithOutput {
            let preset = Settings.selectedPreset
            width = preset.width
            height = preset.height
        }
        threadsPerGrid = MTLSize(
            width: width,
            height: height,
            depth: 1
        )
    }
    
    func getCurrentPresentationTimestamp() -> CMTime? {
        currentSampleBuffer?.presentationTimeStamp
    }
    
    func setCombinedOverlay(_ combinedOverlay: CombinedOverlay?) {
        guard let combinedOverlay else {
            self.overlayTexture = nil
            return
        }
        guard let metalDevice, let imprintPipeline else {
            LOG("Metal device has not been initialized", level: .error)
            return
        }

        boundingBoxData = [] // reset data and precalculate these again
        let w = imprintPipeline.threadExecutionWidth
        let h = imprintPipeline.maxTotalThreadsPerThreadgroup / w
        let threadsPerThreadgroup = MTLSizeMake(w, h, 1)

        if combinedOverlay.coverage > 0.75 {
            var imprintArguments = ImprintArguments()
            imprintArguments.widthRatio = lumaChromaWidthRatio
            imprintArguments.heightRatio = lumaChromaHeightRatio
            imprintArguments.offsetX = 0
            imprintArguments.offsetY = 0

            let imprintArgumentBuffer = metalDevice.makeBuffer(
                bytes: &imprintArguments,
                length: MemoryLayout<ImprintArguments>.size,
                options: [.cpuCacheModeWriteCombined]
            )
            let threadsPerGrid = MTLSize(
                width: Int(combinedOverlay.image.extent.width),
                height: Int(combinedOverlay.image.extent.height),
                depth: 1
            )
            if let imprintArgumentBuffer {
                boundingBoxData.append((imprintArgumentBuffer, threadsPerGrid, threadsPerThreadgroup))
            }
            LOG("Created Metal buffer for the entire overlay", level: .debug)
        }
        else {
            for box in combinedOverlay.boundingBoxes {
                var imprintArguments = ImprintArguments()
                imprintArguments.widthRatio = lumaChromaWidthRatio
                imprintArguments.heightRatio = lumaChromaHeightRatio
                imprintArguments.offsetX = UInt32(box.origin.x)
                imprintArguments.offsetY = UInt32(box.origin.y)

                let imprintArgumentBuffer = metalDevice.makeBuffer(
                    bytes: &imprintArguments,
                    length: MemoryLayout<ImprintArguments>.size,
                    options: [.cpuCacheModeWriteCombined]
                )
                let threadsPerGrid = MTLSize(
                    width: Int(box.size.width),
                    height: Int(box.size.height),
                    depth: 1
                )
                if let imprintArgumentBuffer {
                    boundingBoxData.append((imprintArgumentBuffer, threadsPerGrid, threadsPerThreadgroup))
                }
            }
            LOG("Created Metal buffers for \(boundingBoxData.count) bounding boxes in the overlay", level: .debug)
        }
        
        let image = combinedOverlay.image
        
        // create a texture from the CIImage
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)

        // 3. Create a MTLTextureDescriptor
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.pixelFormat = .rgba16Unorm // Or choose the appropriate format based on your CIImage
        textureDescriptor.width = width
        textureDescriptor.height = height
        textureDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget] // Adjust usage as needed

        guard let texture = metalDevice.makeTexture(descriptor: textureDescriptor) else {
            LOG("Could not create Metal texture from the combined overlay", level: .error)
            return
        }
        guard let commandQueue, let commandBuffer = commandQueue.makeCommandBuffer() else {
            LOG("Could not create command buffer to render the combined overlay", level: .error)
            return
        }
        context.render(image, to: texture, commandBuffer: commandBuffer, bounds: image.extent, colorSpace: image.colorSpace ?? CG_COLOR_SPACE)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        self.overlayTexture = texture
    }
    
    func createTextures(from sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), let textureCache else {
            LOG("Cannot get pixel buffer from sample buffer", level: .error)
            return
        }

        if measureTextures {
            lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
            chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            lumaChromaWidthRatio = UInt32(lumaWidth / chromaWidth)
            lumaChromaHeightRatio = UInt32(lumaHeight / chromaHeight)
            
            for kernel in kernels.keys {
                let args = kernels[kernel]!.args
                let argsPointer = args.contents().bindMemory(to: KernelArguments.self, capacity: 1)
                argsPointer.pointee.widthRatio = lumaChromaWidthRatio
                argsPointer.pointee.heightRatio = lumaChromaHeightRatio
            }
            for (args, _, _) in boundingBoxData {
                let argsPointer = args.contents().bindMemory(to: ImprintArguments.self, capacity: 1)
                argsPointer.pointee.widthRatio = lumaChromaWidthRatio
                argsPointer.pointee.heightRatio = lumaChromaHeightRatio
            }
            
            measureTextures = false
        }
        var newLumaTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r16Unorm,
            lumaWidth,
            lumaHeight,
            0,
            &newLumaTexture
        )
        var newChromaTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rg16Unorm,
            chromaWidth,
            chromaHeight,
            1,
            &newChromaTexture
        )
        lumaTexture = newLumaTexture
        chromaTexture = newChromaTexture
    }
    
    func apply(kernel: String, strength: Float, encoder: MTLComputeCommandEncoder) {
        guard let lumaTexture, let chromaTexture, let kernelSettings = kernels[kernel] else {
            LOG("Could not create a texture from the pixel buffer planes", level: .error)
            return
        }
        
        let argsPointer = kernelSettings.args.contents().bindMemory(to: KernelArguments.self, capacity: 1)
        argsPointer.pointee.strength = strength
        argsPointer.pointee.frame = frameNumber
                
        encoder.setComputePipelineState(kernelSettings.pipeline)
        encoder.setTexture(CVMetalTextureGetTexture(lumaTexture), index: 0)
        encoder.setTexture(CVMetalTextureGetTexture(chromaTexture), index: 1)
        encoder.setBuffer(kernelSettings.args, offset: 0, index: 0)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: kernelSettings.threads)
    }

    func imprintOverlay(encoder: MTLComputeCommandEncoder) {
        guard let lumaTexture, let chromaTexture, let imprintPipeline else {
            LOG("Could not create a texture from the pixel buffer planes", level: .error)
            return
        }
        
        encoder.setComputePipelineState(imprintPipeline)
        encoder.setTexture(CVMetalTextureGetTexture(lumaTexture), index: 0)
        encoder.setTexture(CVMetalTextureGetTexture(chromaTexture), index: 1)
        encoder.setTexture(overlayTexture, index: 2)

        for (imprintArgumentBuffer, threadsPerGrid, threadsPerThreadgroup) in boundingBoxData {
            encoder.setBuffer(imprintArgumentBuffer, offset: 0, index: 0)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        }
    }
    
    func processFrame(sampleBuffer: CMSampleBuffer) async {
        currentSampleBuffer = sampleBuffer
        nonisolated(unsafe) let sendableSampleBuffer = sampleBuffer // removes the need for @preconcurrency
        if grabbingFrames {
            if style != nil || effect != nil || overlayTexture != nil {
                frameNumber += 1
                frameNumber %= 600 // restart counter every 600 frames
                createTextures(from: sendableSampleBuffer)
                guard let commandBuffer = commandQueue?.makeCommandBuffer(),
                      let encoder = commandBuffer.makeComputeCommandEncoder() else {
                    LOG("Could not create Metal objects", level: .error)
                    return
                }
                if let style {
                    apply(kernel: style, strength: styleStrength, encoder: encoder)
                }
                if let effect {
                    apply(kernel: effect, strength: effectStrength, encoder: encoder)
                }
                if overlayTexture != nil {
                    imprintOverlay(encoder: encoder)
                }
                encoder.endEncoding()
                commandBuffer.commit()
            }
            if await Streamer.shared.isStreaming() {
                await ContentPackager.shared.appendVideoSampleBuffer(sendableSampleBuffer)
            }
            if await Streamer.shared.getMonitor() == .output {
                await OutputMonitorView.enqueue(sendableSampleBuffer)
            }
        }
    }

}

final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    @PipelineActor public static let shared = FrameGrabber()
    private let frameTinkerer = FrameTinkerer()

    func resetTinkerer() async {
        await frameTinkerer.reset()
    }
    
    func commenceGrabbing() async {
        if await !frameTinkerer.isActive() {
            await frameTinkerer.reset()
            await frameTinkerer.refreshStyle()
            await frameTinkerer.refreshEffect()
            await frameTinkerer.start()
            LOG("Started grabbing frames", level: .debug)
        }
        else {
            LOG("Frame grabbing already started", level: .debug)
        }
    }
    func terminateGrabbing() async {
        if await frameTinkerer.isActive() {
            await frameTinkerer.stop()
            LOG("Stopped grabbing frames", level: .debug)
        }
        else {
            LOG("Frame grabbing already stopped", level: .debug)
        }
    }
    func refreshStyle() async {
        await frameTinkerer.refreshStyle()
    }
    func setStyleStrength(to strength: Float) async {
        await frameTinkerer.setStyleStrength(strength)
    }
    func refreshEffect() async {
        await frameTinkerer.refreshEffect()
    }
    func setEffectStrength(to strength: Float) async {
        await frameTinkerer.setEffectStrength(strength)
    }
    func setCombinedOverlay(_ combinedOverlay: CombinedOverlay?) async {
        await frameTinkerer.setCombinedOverlay(combinedOverlay)
    }
    func getCurrentPresentationTimestamp() async -> CMTime? {
        await frameTinkerer.getCurrentPresentationTimestamp()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let sendableSampleBuffer = sampleBuffer
        Task { @PipelineActor in
            await frameTinkerer.processFrame(sampleBuffer: sendableSampleBuffer)
            semaphore.signal()
        }
        semaphore.wait()
    }
}


