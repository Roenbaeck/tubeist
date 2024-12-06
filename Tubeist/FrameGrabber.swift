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
        STREAMING_QUEUE.async {
            Task.detached {
                switch output {
                case is AVCaptureVideoDataOutput:
                    if let overlayImage = await WebOverlayViewController.shared.getOverlayImage() {
                        await self.overlayImprinter.imprint(overlay: overlayImage, onto: sampleBuffer)
                    }
                    self.assetInterceptor.appendVideoSampleBuffer(sampleBuffer)
                case is AVCaptureAudioDataOutput:
                    self.assetInterceptor.appendAudioSampleBuffer(sampleBuffer)
                default:
                    print("Unknown output type")
                }
            }
        }
    }
}


/*
struct AudioLevelMeter: View {
    @Binding var audioLevel: Float
    
    // Constants for customization
    private let numberOfSegments = 20
    private let spacing: CGFloat = 2
    private let cornerRadius: CGFloat = 4
    private let minWidthFactor: CGFloat = 0.3
    private let animationDuration = 0.1
    private let verticalPadding: CGFloat = 20  // Added padding constant
    
    // Colors for different levels
    private let lowColor = Color.green
    private let midColor = Color.yellow
    private let highColor = Color.red
    
    private func colorForSegment(_ index: Int) -> Color {
        let segmentPercent = Double(index) / Double(numberOfSegments)
        switch segmentPercent {
        case 0.0..<0.6: return lowColor
        case 0.6..<0.8: return midColor
        default: return highColor
        }
    }
    
    private func segmentWidth(_ geometry: GeometryProxy, index: Int) -> CGFloat {
        let baseWidth = geometry.size.width
        let widthIncrease = (1 - minWidthFactor) * Double(index) / Double(numberOfSegments)
        return baseWidth * (minWidthFactor + widthIncrease)
    }
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: spacing) {
                Spacer(minLength: verticalPadding)  // Top padding
                
                ForEach((0..<numberOfSegments).reversed(), id: \.self) { index in
                    let isActive = Float(index) / Float(numberOfSegments) <= audioLevel
                    
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(colorForSegment(index))
                        .frame(width: segmentWidth(geometry, index: index))
                        .opacity(isActive ? 1.0 : 0.1)
                        .animation(.easeOut(duration: animationDuration), value: isActive)
                        .shadow(color: isActive ? colorForSegment(index).opacity(0.5) : .clear,
                               radius: isActive ? 2 : 0)
                }
                
                Spacer(minLength: verticalPadding)  // Bottom padding
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}


class AudioLevelDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var onAudioLevelUpdate: (Float) -> Void
    private var peakHoldLevel: Float = 0
    private let decayRate: Float = 0.2
    private var recordingManager: RecordingManager
    
    init(onAudioLevelUpdate: @escaping (Float) -> Void, recordingManager: RecordingManager) {
        self.onAudioLevelUpdate = onAudioLevelUpdate
        self.recordingManager = recordingManager
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let channel = connection.audioChannels.first else { return }
        
        let power = channel.averagePowerLevel
        let normalizedPower = pow(10, power / 20)
        
        // Implement peak holding with decay
        if normalizedPower > peakHoldLevel {
            peakHoldLevel = normalizedPower
        } else {
            peakHoldLevel = max(0, peakHoldLevel - decayRate)
        }
        
        // Normalize and smooth the level
        let normalizedLevel = normalizeAudioLevel(peakHoldLevel)
        self.onAudioLevelUpdate(normalizedLevel)
        // forward
        recordingManager.captureOutput(output, didOutput: sampleBuffer, from: connection)
    }
    
    private func normalizeAudioLevel(_ level: Float) -> Float {
        let minDb: Float = -60
        let maxDb: Float = 0
        let db = 20 * log10(level)
        let normalizedDb = (db - minDb) / (maxDb - minDb)
        return min(max(normalizedDb, 0), 1)
    }
}

*/
