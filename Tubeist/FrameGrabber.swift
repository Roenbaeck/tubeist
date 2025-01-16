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
    private var strengthBuffer: MTLBuffer?
    private var styles: [String: MTLComputePipelineState] = [:]
    // keeping one and the same render destination currently introduces flicker
    private var renderDestination: CIRenderDestination?
    
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
        self.strengthBuffer = metalDevice.makeBuffer(length: MemoryLayout<Float>.size, options: [])
        let library = metalDevice.makeDefaultLibrary()
        for style in AVAILABLE_STYLES.filter( { $0 != NO_STYLE } ) {
            guard let function = library?.makeFunction(name: style.lowercased()) else {
                LOG("Could not make function with the shader source provided", level: .error)
                return
            }
            do {
                let pipeline = try metalDevice.makeComputePipelineState(function: function)
                styles[style] = pipeline
            }
            catch {
                LOG("Could not create compute pipeline state", level: .error)
                return
            }
        }
    }
    
    func reset() {
        renderDestination = nil
    }
    
    func effect(style: String, strength: Float, onto sampleBuffer: CMSampleBuffer) {
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
        
        guard let pipelineState = styles[style] else {
            LOG("The pipeline state is not initialized", level: .error)
            return
        }
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(yTexture, index: 0)
        encoder.setTexture(cbcrTexture, index: 1)
        guard let strengthPointer = strengthBuffer?.contents().assumingMemoryBound(to: Float.self) else {
            LOG("Unable to bind the strength buffer", level: .error)
            return
        }
        strengthPointer[0] = strength
        encoder.setBuffer(strengthBuffer, offset: 0, index: 0)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (yTexture.width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (yTexture.height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )
        
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
        destination.alphaMode = .premultiplied

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
    private var strength: Float = 1.0

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
    func setStrength(_ strength: Float) {
        self.strength = strength
    }
    func getStrength() -> Float {
        strength
    }
}

final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    @PipelineActor public static let shared = FrameGrabber()
    private let frameTinkerer = FrameTinkerer()
    private let frameGrabbing = FrameGrabbingActor()
    
    func commenceGrabbing() async {
        if await !frameGrabbing.isActive() {
            await frameTinkerer.reset()
            await frameGrabbing.refreshStyle()
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
    func setStrength(to strength: Float) async {
        await frameGrabbing.setStrength(strength)
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
                        await self.frameTinkerer.effect(style: style, strength: self.frameGrabbing.getStrength(), onto: sendableSampleBuffer)
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


