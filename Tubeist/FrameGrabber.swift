//
//  FrameGrabber.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-05.
//

import AVFoundation
import CoreImage
import Metal

private actor FrameTinkerer {
    private let context: CIContext
    private var metalDevice: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var lumaTexture: MTLTexture?
    private var chromaTexture: MTLTexture?
    private var kernels: [String: MTLComputePipelineState] = [:]
    private var threads: [String: MTLSize] = [:]
    private var strengths: [String: (MTLBuffer, UnsafeMutablePointer<Float>)] = [:]
    private var widths: [String: (MTLBuffer, UnsafeMutablePointer<UInt32>)] = [:]
    private var heights: [String: (MTLBuffer, UnsafeMutablePointer<UInt32>)] = [:]
    private var frameNumberBuffer: MTLBuffer?
    private var frameNumberPointer: UnsafeMutablePointer<UInt32>?
    // overlay imprinting
    private var overlayTexture: MTLTexture?
    private var imprintPipeline: MTLComputePipelineState?
    private var boundingBoxData: [(MTLBuffer, MTLSize, MTLSize)] = []
    
    // resettable
    private var frameNumber: UInt32 = 0
    private var threadsPerGrid: MTLSize = MTLSize(
        width: DEFAULT_CAPTURE_WIDTH,
        height: DEFAULT_CAPTURE_HEIGHT,
        depth: 1
    )

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
        let library = metalDevice.makeDefaultLibrary()
        self.frameNumberBuffer = metalDevice.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared)
        self.frameNumberPointer = frameNumberBuffer?.contents().assumingMemoryBound(to: UInt32.self)
        var kernelNames = AVAILABLE_STYLES.filter( { $0 != NO_STYLE } )
        kernelNames.append(contentsOf: AVAILABLE_EFFECTS.filter( { $0 != NO_EFFECT } ))
                                                   
        for kernel in kernelNames {
            guard let function = library?.makeFunction(name: kernel.lowercased()) else {
                LOG("Could not make function out of kernel code '\(kernel)'", level: .error)
                return
            }
            do {
                let pipeline = try metalDevice.makeComputePipelineState(function: function)
                kernels[kernel] = pipeline
                if let buffer = metalDevice.makeBuffer(length: MemoryLayout<Float>.size, options: .storageModeShared) {
                    strengths[kernel] = (buffer, buffer.contents().assumingMemoryBound(to: Float.self))
                }
                if let buffer = metalDevice.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared) {
                    widths[kernel] = (buffer, buffer.contents().assumingMemoryBound(to: UInt32.self))
                }
                if let buffer = metalDevice.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared) {
                    heights[kernel] = (buffer, buffer.contents().assumingMemoryBound(to: UInt32.self))
                }
                // calculating optimum threadgroup and grid sizes
                let w = pipeline.threadExecutionWidth
                let h = pipeline.maxTotalThreadsPerThreadgroup / w
                threads[kernel] = MTLSize(width: w, height: h, depth: 1)
            }
            catch {
                LOG("Failed to create pipeline state: \(error)", level: .error)
                return
            }
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
    
    func reset() {
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
            let boxBuffer = metalDevice.makeBuffer(length: MemoryLayout<SIMD2<Float>>.size, options: .storageModeShared)
            let boxPointer = boxBuffer?.contents().assumingMemoryBound(to: SIMD2<Float>.self)
            boxPointer?.pointee = SIMD2<Float>(Float(0), Float(0))

            let threadsPerGrid = MTLSize(
                width: Int(combinedOverlay.image.extent.width),
                height: Int(combinedOverlay.image.extent.height),
                depth: 1
            )
            
            if let boxBuffer {
                boundingBoxData.append((boxBuffer, threadsPerGrid, threadsPerThreadgroup))
            }
            LOG("Created Metal buffer for the entire overlay", level: .debug)
        }
        else {
            for box in combinedOverlay.boundingBoxes {
                // Set buffer for bounding boxes
                let boxBuffer = metalDevice.makeBuffer(length: MemoryLayout<SIMD2<Float>>.size, options: .storageModeShared)
                let boxPointer = boxBuffer?.contents().assumingMemoryBound(to: SIMD2<Float>.self)
                boxPointer?.pointee = SIMD2<Float>(Float(box.origin.x), Float(box.origin.y))
                
                let threadsPerGrid = MTLSize(
                    width: Int(box.size.width),
                    height: Int(box.size.height),
                    depth: 1
                )
                
                if let boxBuffer {
                    boundingBoxData.append((boxBuffer, threadsPerGrid, threadsPerThreadgroup))
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
    
    func updateTextures(from sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let textureCache else {
            LOG("Could not get pixel buffer from sample buffer", level: .error)
            return
        }
        var lumaTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r16Unorm,
            CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
            0,
            &lumaTexture
        )
        if let lumaTexture {
            self.lumaTexture = CVMetalTextureGetTexture(lumaTexture)
        }
        
        var chromaTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rg16Unorm,
            CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
            1,
            &chromaTexture
        )
        if let chromaTexture {
            self.chromaTexture = CVMetalTextureGetTexture(chromaTexture)
        }
    }
    
    func apply(kernel: String, strength: Float, onto sampleBuffer: CMSampleBuffer) {
        frameNumber += 1
        frameNumber %= 600 // restart counter every 600 frames

        guard let lumaTexture,
              let chromaTexture
        else {
            LOG("Could not create a texture from the pixel buffer planes", level: .error)
            return
        }

        guard let commandBuffer = commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            LOG("Could not create a commmand buffer or encoder", level: .error)
            return
        }
        
        guard let pipelineState = kernels[kernel] else {
            LOG("The pipeline state is not initialized", level: .error)
            return
        }
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(lumaTexture, index: 0)
        encoder.setTexture(chromaTexture, index: 1)
        guard let (strengthBuffer, strengthPointer) = strengths[kernel] else {
            LOG("Unable to bind the strength buffer", level: .error)
            return
        }
        strengthPointer.pointee = strength
        encoder.setBuffer(strengthBuffer, offset: 0, index: 0)
        if let frameNumberPointer = frameNumberPointer {
            frameNumberPointer.pointee = frameNumber
            encoder.setBuffer(frameNumberBuffer, offset: 0, index: 1)
        }
        guard let threadsPerThreadgroup = threads[kernel] else {
            LOG("Threads per threadgroup has not been determined", level: .error)
            return
        }
        guard let (widthBuffer, widthPointer) = widths[kernel] else {
            LOG("Unable to bind the width buffer", level: .error)
            return
        }
        widthPointer.pointee = UInt32(threadsPerThreadgroup.width)
        encoder.setBuffer(widthBuffer, offset: 0, index: 2)
        guard let (heightBuffer, heightPointer) = heights[kernel] else {
            LOG("Unable to bind the height buffer", level: .error)
            return
        }
        heightPointer.pointee = UInt32(threadsPerThreadgroup.height)
        encoder.setBuffer(heightBuffer, offset: 0, index: 3)
        
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
    }

    func imprintOverlay(onto sampleBuffer: CMSampleBuffer) {
        guard let overlayTexture else {
            return // quick return if there is no overlay to imprint
        }

        guard let lumaTexture,
              let chromaTexture
        else {
            LOG("Could not create a texture from the pixel buffer planes", level: .error)
            return
        }
        
        guard let commandBuffer = commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder(),
              let imprintPipeline else {
            LOG("Could not create a commmand buffer, encoder, or imprint pipeline", level: .error)
            return
        }

        encoder.setComputePipelineState(imprintPipeline)
        encoder.setTexture(lumaTexture, index: 0)
        encoder.setTexture(chromaTexture, index: 1)
        encoder.setTexture(overlayTexture, index: 2)

        for (boxBuffer, threadsPerGrid, threadsPerThreadgroup) in boundingBoxData {
            encoder.setBuffer(boxBuffer, offset: 0, index: 0)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        }

        encoder.endEncoding()
        commandBuffer.commit()
    }
}

private actor FrameGrabbingActor {
    private var grabbingFrames: Bool = false
    private var style: String?
    private var styleStrength: Float = 1.0
    private var effect: String?
    private var effectStrength: Float = 1.0

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
}

final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    @PipelineActor public static let shared = FrameGrabber()
    private let frameTinkerer = FrameTinkerer()
    private let frameGrabbing = FrameGrabbingActor()

    func resetTinkerer() async {
        await frameTinkerer.reset()
    }
    
    func commenceGrabbing() async {
        if await !frameGrabbing.isActive() {
            await frameTinkerer.reset()
            await frameGrabbing.refreshStyle()
            await frameGrabbing.refreshEffect()
            await frameGrabbing.start()
            LOG("Started grabbing frames", level: .debug)
        }
        else {
            LOG("Frame grabbing already started", level: .debug)
        }
    }
    func terminateGrabbing() async {
        if await frameGrabbing.isActive() {
            await frameGrabbing.stop()
            LOG("Stopped grabbing frames", level: .debug)
        }
        else {
            LOG("Frame grabbing already stopped", level: .debug)
        }
    }
    func refreshStyle() async {
        await frameGrabbing.refreshStyle()
    }
    func setStyleStrength(to strength: Float) async {
        await frameGrabbing.setStyleStrength(strength)
    }
    func refreshEffect() async {
        await frameGrabbing.refreshEffect()
    }
    func setEffectStrength(to strength: Float) async {
        await frameGrabbing.setEffectStrength(strength)
    }
    func setCombinedOverlay(_ combinedOverlay: CombinedOverlay?) async {
        await frameTinkerer.setCombinedOverlay(combinedOverlay)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        nonisolated(unsafe) let sendableSampleBuffer = sampleBuffer // removes the need for @preconcurrency
        PipelineActor.queue.async {
            Task { @PipelineActor [sendableSampleBuffer] in
                nonisolated(unsafe) let sendableSampleBuffer = sendableSampleBuffer // it's needed again here
                if await self.frameGrabbing.isActive() {
                    await self.frameTinkerer.updateTextures(from: sendableSampleBuffer)
                    if let style = await self.frameGrabbing.getStyle() {
                        await self.frameTinkerer.apply(kernel: style, strength: self.frameGrabbing.getStyleStrength(), onto: sendableSampleBuffer)
                    }
                    if let effect = await self.frameGrabbing.getEffect() {
                        await self.frameTinkerer.apply(kernel: effect, strength: self.frameGrabbing.getEffectStrength(), onto: sendableSampleBuffer)
                    }
                    await self.frameTinkerer.imprintOverlay(onto: sendableSampleBuffer)
                    if await Streamer.shared.isStreaming() {
                        await ContentPackager.shared.appendVideoSampleBuffer(sendableSampleBuffer)
                    }
                    if await Streamer.shared.getMonitor() == .output {
                        await OutputMonitorView.enqueue(sendableSampleBuffer)
                    }
                }
            }
        }
    }
}


