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
        guard let videoPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            fatalError("Unable to get pixel buffer from sample buffer")
        }
        
        let destination = CIRenderDestination(pixelBuffer: videoPixelBuffer)
        destination.blendKernel = CIBlendKernel.sourceOver
        destination.blendsInDestinationColorSpace = true
        destination.alphaMode = .premultiplied
        do {
            let task = try self.context.startTask(toRender: overlayImage, to: destination)
            try task.waitUntilCompleted()
        } catch {
            print("Error rendering overlay: \(error)")
        }
    }
}

final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
    public static let shared = FrameGrabber()
    private let assetInterceptor = AssetInterceptor.shared
    private let overlayImprinter = OverlayImprinter()
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        STREAMING_QUEUE_CONCURRENT.async {
            Task.detached {
                if await Streamer.shared.isStreaming() {
                    switch output {
                    case is AVCaptureVideoDataOutput:
                        if let overlayImage = await OverlayBundler.shared.getCombinedImage() {
                            await self.overlayImprinter.imprint(overlay: overlayImage, onto: sampleBuffer)
                        }
                        else {
                            print("No overlay available to imprint")
                        }
                        await self.assetInterceptor.appendVideoSampleBuffer(sampleBuffer)
                    case is AVCaptureAudioDataOutput:
                        await self.assetInterceptor.appendAudioSampleBuffer(sampleBuffer)
                    default:
                        print("Unknown output type")
                    }
                }
            }
        }
    }
}


