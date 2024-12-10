//
//  CameraMonitor.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-04.
//

// @preconcurrency needed to pass previewLayer across boundary
@preconcurrency import AVFoundation
import SwiftUI

private actor CameraActor {
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let frameGrabber = FrameGrabber.shared
    // Had to add this to pass previewLayer across boundary
    nonisolated(unsafe) private let previewLayer: AVCaptureVideoPreviewLayer
    
    init() {
        // Set all immutables
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        
        // Get devices
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let audioDevice = AVCaptureDevice.default(for: .audio) else {
            print("No camera or microphone found")
            return
        }
        // Configure the capture
        do {
            
            // Set session preset before adding inputs/outputs
            switch CAPTURE_WIDTH {
            case 1280: session.sessionPreset = .hd1280x720
            case 1920: session.sessionPreset = .hd1920x1080
            case 3840: session.sessionPreset = .hd4K3840x2160
            default: break
            }
            
            session.automaticallyConfiguresCaptureDeviceForWideColor = true
            
            // videoDevice.listFormats()
            
            guard let format = videoDevice.findFormat() else {
                print("Desired format not found")
                return
            }
            
            videoDevice.printFormatDetails(captureFormat: format)
            
            // Apply the format to the video device
            try videoDevice.lockForConfiguration()
            videoDevice.activeFormat = format
            let frameDurationParts = Int64(TIMESCALE / FRAMERATE)
            videoDevice.activeVideoMinFrameDuration = CMTimeMake(value: frameDurationParts, timescale: Int32(TIMESCALE))
            videoDevice.activeVideoMaxFrameDuration = CMTimeMake(value: frameDurationParts, timescale: Int32(TIMESCALE))
            videoDevice.activeColorSpace = .HLG_BT2020
            
            videoDevice.unlockForConfiguration()
            
            // Add video input to the session
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            } else {
                print("Cannot add video input")
                return
            }
            // Add video output to the session
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            } else {
                print("Cannot add video output")
                return
            }

            
            // Add audio input to the session
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
            } else {
                print("Cannot add audio input")
                return
            }
            // Add audio output to the session
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            } else {
                print("Cannot add audio output")
                return
            }

            


            
            
            
            /*
             // Find the video connection and enable stabilization
             if let connection = videoOutput.connection(with: .video) {
             if connection.isVideoStabilizationSupported {
             connection.preferredVideoStabilizationMode = .standard
             print("Video stabilization enabled: Standard")
             } else {
             print("Video stabilization is not supported for this connection.")
             }
             } else {
             print("Failed to get video connection.")
             }
             */
            
            
        } catch {
            print("Error setting up camera: \(error)")
        }
    }
    
    func startOutput() {
        videoOutput.setSampleBufferDelegate(frameGrabber, queue: STREAMING_QUEUE)
        audioOutput.setSampleBufferDelegate(frameGrabber, queue: STREAMING_QUEUE)
    }
    
    func stopOutput() {
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        audioOutput.setSampleBufferDelegate(nil, queue: nil)
    }
    
    func startRunning() {
         session.startRunning()
    }
    
    func stopRunning() {
        session.stopRunning()
    }
    
    func getSession() -> AVCaptureSession {
        session
    }

    func getAudioChannels() -> [AVCaptureAudioChannel] {
        return audioOutput.connections.first?.audioChannels ?? []
    }
    
    
    // Method to configure preview layer directly on the view controller
    func configurePreviewLayer(on viewController: UIViewController) {
            previewLayer.videoGravity = .resizeAspect
            
            // Configure connection rotation
            if let connection = previewLayer.connection {
                if connection.isVideoRotationAngleSupported(0) {
                    connection.videoRotationAngle = 0
                }
            }
            
            // Explicitly dispatch to main queue
            DispatchQueue.main.async {
                // Remove existing preview layers
                viewController.view.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
                
                // Add preview layer
                viewController.view.layer.addSublayer(self.previewLayer)
                
                // Update frame
                CATransaction.begin()
                CATransaction.setAnimationDuration(0)
                self.previewLayer.frame = viewController.view.bounds
                CATransaction.commit()
            }
    }
}


final class CameraMonitor: Sendable {
    public static let shared = CameraMonitor()
    private let camera = CameraActor()
    
    // Methods to interact with the camera via the actor
    func startCamera() async {
        await camera.startRunning()
    }
    func stopCamera() async {
        await camera.stopRunning()
    }
    func startOutput() async {
        await camera.startOutput()
    }
    func stopOutput() async {
        await camera.stopOutput()
    }
    func getAudioChannels() async -> [AVCaptureAudioChannel] {
        return await camera.getAudioChannels()
    }
    
    func configurePreviewLayer(on viewController: UIViewController) {
        Task {
            await camera.configurePreviewLayer(on: viewController)
        }
    }
}



// Extend AVCaptureDevice to include findFormat method
extension AVCaptureDevice {
    func printFormatDetails(captureFormat: AVCaptureDevice.Format) {
        print("----------============ \(captureFormat.formatDescription.mediaSubType.rawValue) ============----------")
        print("Supports \(captureFormat.formatDescription)")
        print("HDR: \(captureFormat.isVideoHDRSupported)")
        print("Frame range: \(captureFormat.videoSupportedFrameRateRanges)")
        print("Spatial video: \(captureFormat.isSpatialVideoCaptureSupported)")
        print("Background replacement: \(captureFormat.isBackgroundReplacementSupported)")
        print("Binned: \(captureFormat.isVideoBinned)")
        print("Multi-cam: \(captureFormat.isMultiCamSupported)")
        print("FOV: \(captureFormat.videoFieldOfView)")
        print("Color spaces: \(captureFormat.supportedColorSpaces)")
        print("ISO: \(captureFormat.minISO) - \(captureFormat.maxISO)")
        print("Exposure: \(captureFormat.minExposureDuration) - \(captureFormat.maxExposureDuration)")
        print("Max zoom: \(captureFormat.videoMaxZoomFactor) (native zoom: \(captureFormat.secondaryNativeResolutionZoomFactors))")
        print("AF: \(captureFormat.autoFocusSystem)")
    }
    func listFormats() {
        for captureFormat in formats {
            printFormatDetails(captureFormat: captureFormat)
        }
    }
    func findFormat() -> AVCaptureDevice.Format? {
        for captureFormat in formats {
            if captureFormat.formatDescription.mediaSubType.rawValue == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange {
                let description = captureFormat.formatDescription as CMFormatDescription
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                
                if dimensions.width == CAPTURE_WIDTH && dimensions.height == CAPTURE_HEIGHT,
                   let frameRateRange = captureFormat.videoSupportedFrameRateRanges.first,
                   frameRateRange.maxFrameRate >= Float64(FRAMERATE),
                   captureFormat.isVideoHDRSupported,
                   !captureFormat.isMultiCamSupported, // avoid this to get a different 4:2:2 with higher refresh rates
                   captureFormat.maxISO >= 5184.0 {
                    print("Desired format found")
                    return captureFormat
                }
            }
        }
        return nil
    }
}

struct CameraMonitorView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let viewController = UIViewController()
        // Ensure view is loaded before configurations
        viewController.loadViewIfNeeded()
        return viewController
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        let cameraMonitor = CameraMonitor.shared
        cameraMonitor.configurePreviewLayer(on: uiViewController)
    }
}

struct AudioLevelView: View {
    @Environment(AppState.self) var appState
    @State private var audioLevels: [Float] = Array(repeating: -160, count: AUDIO_BARS)
    @State private var peakLevels: [Float] = Array(repeating: -160, count: AUDIO_BARS)
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    
    private func normalizeLevel(_ level: Float) -> CGFloat {
        let normalizedLevel = max(0, level + 160) / 160  // Ensure level is in the 0-1 range

        // Apply the sigmoid function
        let sigmoid = 1 / (1 + exp(-25 * (normalizedLevel - 0.95)))

        return CGFloat(sigmoid) * 50 // Scale to your desired output range (0-50)
    }
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach((0..<AUDIO_BARS).reversed(), id: \.self) { index in
                VStack {
                    // Overlapping white bar and semi-transparent black bar
                    ZStack(alignment: .bottom) {
                        // White background bar with cutout mask
                        Rectangle()
                            .fill(appState.isAudioLevelRunning ? Color.white : Color.white.opacity(0.5))
                            .frame(width: 5, height: normalizeLevel(peakLevels[index]))
                            .mask(
                                Rectangle()
                                    .frame(width: 5, height: normalizeLevel(audioLevels[index]))
                            )
                    }
                }
                .animation(.easeInOut, value: audioLevels[index])
                .onTapGesture {
                    appState.isAudioLevelRunning.toggle()
                }
            }
        }
        .onReceive(timer) { _ in
            guard appState.isAudioLevelRunning else { return }
            
            Task {
                let channels = await CameraMonitor.shared.getAudioChannels()
                if let channel = channels.first {
                    // Rotate and add new levels
                    audioLevels.removeFirst()
                    audioLevels.append(channel.averagePowerLevel)
                    
                    peakLevels.removeFirst()
                    peakLevels.append(channel.peakHoldLevel)
                }
            }
        }
    }
}


