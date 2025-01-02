//
//  FrameGrabber.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-05.
//

@preconcurrency import AVFoundation
import CoreImage

private actor OverlayImprinter {
    nonisolated(unsafe) private let context: CIContext
    // keeping one and the same render destination currently introduces flicker
    private var renderDestination: CIRenderDestination?
    
    init() {
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
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
    }
    func reset() {
        renderDestination = nil
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
    private var grabbingFrames: Bool = true
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
    private let overlayImprinter = OverlayImprinter()
    private let frameGrabbing = FrameGrabbingActor()
    
    func commenceGrabbing() async {
        await overlayImprinter.reset()
        await frameGrabbing.start()
    }
    func terminateGrabbing() async {
        await frameGrabbing.stop()
        await overlayImprinter.reset()
    }
    
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        Task { @PipelineActor [sampleBuffer] in
            if await self.frameGrabbing.isActive() {
                if let overlay = await OverlayBundler.shared.getOverlay() {
                    await self.overlayImprinter.imprint(overlay: overlay, onto: sampleBuffer)
                }
                if await Streamer.shared.isStreaming() {
                    await AssetInterceptor.shared.appendVideoSampleBuffer(sampleBuffer)
                }
                if await Streamer.shared.getMonitor() == .output {
                    OutputMonitor.shared.enqueue(sampleBuffer)
                }
            }
        }
    }
}


