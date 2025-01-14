//
//  FrameGrabber.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-05.
//

import AVFoundation
import CoreImage
import Metal

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

kernel void applyStyle(texture2d<float, access::read_write> texture [[texture(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    float4 color = texture.read(gid);
    float3 rgb = color.rgb;
    
    // Apply style modifications directly
    rgb *= float3(1.1, 1.0, 0.95); // Example: Warm style
    
    texture.write(float4(rgb, color.a), gid);
}
"""


private actor FrameTinkerer {
    private let context: CIContext
    private var metalDevice: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var pipelineState: MTLComputePipelineState?
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
        let library = try? metalDevice.makeLibrary(source: shaderSource, options: nil)
        guard let function = library?.makeFunction(name: "applyStyle") else {
            LOG("Could not make function with the shader source provided", level: .error)
            return
        }
        self.pipelineState = try? metalDevice.makeComputePipelineState(function: function)
        
    }
    
    func reset() {
        renderDestination = nil
    }
    
    func effect(onto sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let textureCache = textureCache else {
            LOG("Could not get pixel buffer from sample buffer", level: .error)
            return
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rgb10a2Unorm,  // This format handles the YUV to RGB conversion
            width,
            height,
            0,
            &cvTexture
        )
        
        guard let cvTexture = cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            LOG("Could not create a texture from the pixel buffer", level: .error)
            return
        }

        guard let commandBuffer = commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            LOG("Could not create a commmand buffer or encoder", level: .error)
            return
        }
        
        guard let pipelineState else {
            LOG("The pipeline state is not initialized", level: .error)
            return
        }
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(texture, index: 0) // Same texture for input and output
        
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (texture.width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (texture.height + threadGroupSize.height - 1) / threadGroupSize.height,
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
    func start() {
        grabbingFrames = true
    }
    func stop() {
        grabbingFrames = false
    }
    func isActive() -> Bool {
        grabbingFrames
    }
}

final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    @PipelineActor public static let shared = FrameGrabber()
    private let frameTinkerer = FrameTinkerer()
    private let frameGrabbing = FrameGrabbingActor()
    
    func commenceGrabbing() async {
        if await !frameGrabbing.isActive() {
            await frameTinkerer.reset()
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
            await frameTinkerer.reset()
            LOG("Stopped grabbing frames", level: .debug)
        }
        else {
            LOG("Frame grabbing already stopped", level: .debug)
        }
    }
    
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        nonisolated(unsafe) let sendableSampleBuffer = sampleBuffer // removes the need for @preconcurrency
        PipelineActor.queue.async {
            Task { @PipelineActor [sendableSampleBuffer] in
                nonisolated(unsafe) let sendableSampleBuffer = sendableSampleBuffer // it's needed again here
                if await self.frameGrabbing.isActive() {
                    // await self.frameTinkerer.effect(onto: sendableSampleBuffer)
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


