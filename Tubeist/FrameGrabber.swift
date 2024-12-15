//
//  FrameGrabber.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-05.
//

@preconcurrency import AVFoundation
@preconcurrency import CoreImage

actor OverlayImprinter {
    nonisolated(unsafe) private let context: CIContext // CIContext is now a property of the actor
    init() {
        context = CIContext(options: [
            .useSoftwareRenderer: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.itur_2020)!
        ])
    }
    func imprint(overlay overlayImage: CIImage, onto sampleBuffer: CMSampleBuffer) {
        if let videoPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let destination = CIRenderDestination(pixelBuffer: videoPixelBuffer)
            destination.blendKernel = CIBlendKernel.sourceOver
            destination.blendsInDestinationColorSpace = true
            destination.alphaMode = .premultiplied
            do {
                let task = try self.context.startTask(toRender: overlayImage, to: destination)
                try task.waitUntilCompleted()
            } catch {
                LOG("Error rendering overlay: \(error)", level: .error)
            }
        }
        else {
            LOG("Unable to get pixel buffer from sample buffer", level: .error)
        }
    }
}

actor FrameGrabbingActor {
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

final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
    public static let shared = FrameGrabber()
    private let assetInterceptor = AssetInterceptor.shared
    private let overlayImprinter = OverlayImprinter()
    private let frameGrabbing = FrameGrabbingActor()

    func commenceGrabbing() async {
        await frameGrabbing.start()
    }
    func terminateGrabbing() async {
        await frameGrabbing.stop()
    }
    
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        STREAMING_QUEUE_CONCURRENT.async {
            Task.detached {
                if await self.frameGrabbing.isActive() {
                    switch output {
                    case is AVCaptureVideoDataOutput:
                        if let overlayImage = await OverlayBundler.shared.getCombinedImage() {
                            await self.overlayImprinter.imprint(overlay: overlayImage, onto: sampleBuffer)
                        }
                        await self.assetInterceptor.appendVideoSampleBuffer(sampleBuffer)
                    case is AVCaptureAudioDataOutput:
                        await self.assetInterceptor.appendAudioSampleBuffer(sampleBuffer)
                    default:
                        LOG("Unknown output type")
                    }
                }
            }
        }
    }
}


