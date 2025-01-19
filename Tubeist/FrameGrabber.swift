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
    private var kernels: [String: MTLComputePipelineState] = [:]
    private var strengths: [String: (MTLBuffer, UnsafeMutablePointer<Float>)] = [:]
    private var frameNumberBuffer: MTLBuffer?
    private var frameNumberPointer: UnsafeMutablePointer<UInt32>?
    // keeping one and the same render destination currently introduces flicker
    private var renderDestination: CIRenderDestination?
    // resettable
    private var frameNumber: UInt32 = 0
    private var threadGroupSize: MTLSize = MTLSize(width: 16, height: 9, depth: 1)
    private var threadGroups: MTLSize = MTLSize(
        width: (DEFAULT_COMPRESSED_WIDTH + 16 - 1) / 16,
        height: (DEFAULT_COMPRESSED_HEIGHT + 9 - 1) / 9,
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
                LOG("Could not make function with the shader source provided", level: .error)
                return
            }
            do {
                let pipeline = try metalDevice.makeComputePipelineState(function: function)
                kernels[kernel] = pipeline
                if let buffer = metalDevice.makeBuffer(length: MemoryLayout<Float>.size, options: .storageModeShared) {
                    strengths[kernel] = (buffer, buffer.contents().assumingMemoryBound(to: Float.self))
                }
            }
            catch {
                LOG("Could not create compute pipeline state", level: .error)
                return
            }
        }
    }
    
    func reset() {
        renderDestination = nil
        frameNumber = 0
        var width = DEFAULT_CAPTURE_WIDTH
        var height = DEFAULT_CAPTURE_HEIGHT
        if Settings.isInputSyncedWithOutput {
            let preset = Settings.selectedPreset
            width = preset.width
            height = preset.height
        }
        threadGroups = MTLSize(
            width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )
    }
    
    func apply(kernel: String, strength: Float, onto sampleBuffer: CMSampleBuffer) {
        frameNumber += 1
        frameNumber = frameNumber % 600 // restart counter every 600 frames
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let textureCache = textureCache else {
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

        guard let lumaTexture,
              let chromaTexture,
              let yTexture = CVMetalTextureGetTexture(lumaTexture),
              let cbcrTexture = CVMetalTextureGetTexture(chromaTexture)
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
        encoder.setTexture(yTexture, index: 0)
        encoder.setTexture(cbcrTexture, index: 1)
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

        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
    }

    func imprint(overlay combinedOverlay: CombinedOverlay, onto sampleBuffer: CMSampleBuffer) {
        guard let videoPixelBuffer = sampleBuffer.imageBuffer else {
            LOG("Unable to get pixel buffer from sample buffer", level: .error)
            return
        }
        
        let destination = CIRenderDestination(pixelBuffer: videoPixelBuffer)
        destination.blendKernel = CIBlendKernel.sourceOver
        destination.blendsInDestinationColorSpace = true
        destination.alphaMode = .unpremultiplied

        do {
            var renderTasks: [CIRenderTask] = []
            // if more than 75% of the image has visuals, draw the entire image in one sweep
            if combinedOverlay.coverage > 0.75 {
                let task = try self.context.startTask(
                    toRender: combinedOverlay.image,
                    to: destination
                )
                renderTasks.append(task)
            }
            // otherwise draw each bounding box separately
            else {
                for boundingBox in combinedOverlay.boundingBoxes {
                    let task = try self.context.startTask(
                        toRender: combinedOverlay.image,
                        from: boundingBox,
                        to: destination,
                        at: boundingBox.origin
                    )
                    renderTasks.append(task)
                }
            }
            for renderTask in renderTasks {
                try renderTask.waitUntilCompleted()
            }
        } catch {
            LOG("Error rendering overlay: \(error)", level: .error)
        }

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

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        nonisolated(unsafe) let sendableSampleBuffer = sampleBuffer // removes the need for @preconcurrency
        PipelineActor.queue.async {
            Task { @PipelineActor [sendableSampleBuffer] in
                nonisolated(unsafe) let sendableSampleBuffer = sendableSampleBuffer // it's needed again here
                if await self.frameGrabbing.isActive() {
                    if let style = await self.frameGrabbing.getStyle() {
                        await self.frameTinkerer.apply(kernel: style, strength: self.frameGrabbing.getStyleStrength(), onto: sendableSampleBuffer)
                    }
                    if let effect = await self.frameGrabbing.getEffect() {
                        await self.frameTinkerer.apply(kernel: effect, strength: self.frameGrabbing.getEffectStrength(), onto: sendableSampleBuffer)
                    }
                    if let overlay = await OverlayBundler.shared.getOverlay() {
                        await self.frameTinkerer.imprint(overlay: overlay, onto: sendableSampleBuffer)
                    }
                    if await Streamer.shared.isStreaming() {
                        await ContentPackager.shared.appendVideoSampleBuffer(sendableSampleBuffer)
                    }
                    if await Streamer.shared.getMonitor() == .output {
                        OutputMonitor.shared.enqueue(sendableSampleBuffer)
                    }
                }
            }
        }
    }
}


