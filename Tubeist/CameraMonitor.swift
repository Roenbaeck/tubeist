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
    private let videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioDevice: AVCaptureDevice?
    private var audioInput: AVCaptureDeviceInput?
    private let audioOutput = AVCaptureAudioDataOutput()
    private let frameGrabber = FrameGrabber.shared
    private var minZoomFactor: CGFloat = 1.0
    private var maxZoomFactor: CGFloat = 1.0
    private var opticalZoomFactor: CGFloat = 1.0
    // Had to add this to pass previewLayer across boundary
    nonisolated(unsafe) private let previewLayer: AVCaptureVideoPreviewLayer
    
    init(camera: AVCaptureDevice) {
        // Set all immutables
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        
        // Get devices
        self.videoDevice = camera
        self.audioDevice = AVCaptureDevice.default(for: .audio)
        guard let videoDevice = self.videoDevice,
              let audioDevice = self.audioDevice else {
            LOG("No camera or microphone found", level: .error)
            return
        }
        // Configure the capture
        do {
                        
            // videoDevice.listFormats()
            guard let format = videoDevice.findFormat() else {
                LOG("Desired format not found", level: .error)
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
            
            self.minZoomFactor = videoDevice.minAvailableVideoZoomFactor
            self.maxZoomFactor = videoDevice.maxAvailableVideoZoomFactor
            self.opticalZoomFactor = videoDevice.activeFormat.secondaryNativeResolutionZoomFactors.first ?? 1.0
            
            videoOutput.alwaysDiscardsLateVideoFrames = true
            
            self.videoInput = try AVCaptureDeviceInput(device: videoDevice)
            guard let videoInput = self.videoInput else {
                LOG("Could not create video input", level: .error)
                return
            }
                
            // Add video input to the session
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            } else {
                LOG("Cannot add video input", level: .error)
                return
            }
            // Add video output to the session
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            } else {
                LOG("Cannot add video output", level: .error)
                return
            }

            self.audioInput = try AVCaptureDeviceInput(device: audioDevice)
            guard let audioInput = self.audioInput else {
                LOG("Could not create audio input", level: .error)
                return
            }

            // Add audio input to the session
            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
            } else {
                LOG("Cannot add audio input", level: .error)
                return
            }
            // Add audio output to the session
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            } else {
                LOG("Cannot add audio output", level: .error)
                return
            }

            // need to be called after inputs and outputs have been added
            // session.sessionPreset = .inputPriority
            switch CAPTURE_WIDTH {
            case 1280: session.sessionPreset = .hd1280x720
            case 1920: session.sessionPreset = .hd1920x1080
            case 3840: session.sessionPreset = .hd4K3840x2160
            default: break
            }
            session.automaticallyConfiguresCaptureDeviceForWideColor = true
            session.configuresApplicationAudioSessionToMixWithOthers = true

        } catch {
            LOG("Error setting up camera: \(error)", level: .error)
        }
    }
    
    func findSupportedStabilizationModes() -> [String: AVCaptureVideoStabilizationMode] {
        guard let format = videoDevice?.activeFormat else { return [:] }
        var supportedModes: [String: AVCaptureVideoStabilizationMode] = [:]
        
        if format.isVideoStabilizationModeSupported(.off) {
            supportedModes["Off"] = .off
        }
        if format.isVideoStabilizationModeSupported(.standard) {
            supportedModes["Standard"] = .standard
        }
        if format.isVideoStabilizationModeSupported(.cinematic) {
            supportedModes["Cinematic"] = .cinematic
        }
        if format.isVideoStabilizationModeSupported(.cinematicExtended) {
            supportedModes["Cinematic Extended"] = .cinematicExtended
        }
        if format.isVideoStabilizationModeSupported(.cinematicExtendedEnhanced) {
            supportedModes["Cinematic Extended Enhanced"] = .cinematicExtendedEnhanced
        }
        if format.isVideoStabilizationModeSupported(.previewOptimized) {
            supportedModes["Preview Optimized"] = .previewOptimized
        }
        if format.isVideoStabilizationModeSupported(.auto) {
            supportedModes["Auto"] = .auto
        }
        return supportedModes
    }
    
    func getCameraStabilization() -> String {
        return UserDefaults.standard.string(forKey: "CameraStabilization") ?? "Off"
    }
    
    func setCameraStabilization(to stabilization: AVCaptureVideoStabilizationMode) -> Bool {
        // Find the video connection and enable stabilization
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                // Update the video stabilization mode on the connection.
                connection.preferredVideoStabilizationMode = stabilization
            } else {
                LOG("Video stabilization is not supported for this connection.", level: .warning)
                return false
            }
        } else {
            LOG("Failed to get video connection.", level: .error)
            return false
        }
        return true
    }

    func setZoomFactor(_ zoomFactor: CGFloat) {
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = max(1.0, min(zoomFactor, device.activeFormat.videoMaxZoomFactor))
            device.unlockForConfiguration()
        } catch {
            LOG("Failed to set zoom factor: \(error)", level: .error)
        }
    }
    func getMinZoomFactor() -> CGFloat {
        minZoomFactor
    }
    func getMaxZoomFactor() -> CGFloat {
        maxZoomFactor
    }
    func getOpticalZoomFactor() -> CGFloat {
        opticalZoomFactor
    }
    
    func setFocus(at point: CGPoint) {
        guard let device = videoDevice else { return }
        
        do {
            try device.lockForConfiguration()
            
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            
            device.unlockForConfiguration()
        } catch {
            LOG("Focus configuration error: \(error.localizedDescription)", level: .error)
        }
    }
    func setAutoFocus() {
        guard let device = videoDevice else { return }
        
        do {
            try device.lockForConfiguration()
            device.focusMode = .continuousAutoFocus
            device.unlockForConfiguration()
        } catch {
            LOG("Focus configuration error: \(error.localizedDescription)", level: .error)
        }
    }
    
    func setExposure(at point: CGPoint) {
        guard let device = videoDevice else { return }
        
        do {
            try device.lockForConfiguration()
            
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                device.exposureMode = .autoExpose
            }
            
            device.unlockForConfiguration()
        } catch {
            LOG("Exposure configuration error: \(error.localizedDescription)", level: .error)
        }
    }
    func setAutoExposure() {
        guard let device = videoDevice else { return }
        
        do {
            try device.lockForConfiguration()
            device.exposureMode = .continuousAutoExposure
            device.unlockForConfiguration()
        } catch {
            LOG("Exposure configuration error: \(error.localizedDescription)", level: .error)
        }
    }

    func startOutput() {
        videoOutput.setSampleBufferDelegate(frameGrabber, queue: STREAMING_QUEUE_CONCURRENT)
        audioOutput.setSampleBufferDelegate(frameGrabber, queue: STREAMING_QUEUE_CONCURRENT)
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
    
    func isRunning() -> Bool {
        session.isRunning
    }
        
    func getAudioChannels() -> [AVCaptureAudioChannel] {
        return audioOutput.connections.first?.audioChannels ?? []
    }
    
    func getSession() -> AVCaptureSession {
        session
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
            LOG("Preview layer configured", level: .debug)
        }
    }
}

private actor CameraManager {
    
    private var cameraActor: CameraActor?
    private let cameras: [String: AVCaptureDevice.DeviceType]
    private var stabilizations: [String: AVCaptureVideoStabilizationMode] = [:]

    init() {
        var cameraDevicesByName: [String: AVCaptureDevice.DeviceType] = [:]
        
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInTelephotoCamera,
                .builtInTripleCamera
            ],
            mediaType: .video,
            position: .back
        )
      
        for device in discoverySession.devices {
            let name = device.localizedName
            cameraDevicesByName[name] = device.deviceType
        }
        
        cameras = cameraDevicesByName
        LOG("Cameras: \(cameras.keys)", level: .debug)
    }
    
    func refreshStabilizations() async {
        stabilizations = await cameraActor?.findSupportedStabilizationModes() ?? [:]
    }
    func getStabilizations() -> [String] {
        return Array(stabilizations.keys)
    }
    func getCameras() -> [String] {
        return Array(cameras.keys)
    }
    
    func startCamera() async {
        let camera = UserDefaults.standard.string(forKey: "SelectedCamera") ?? DEFAULT_CAMERA
        guard let cameraType = cameras[camera] else {
            LOG("Cannot find camera \(camera)", level: .error)
            return
        }
        guard let videoDevice = AVCaptureDevice.default(cameraType, for: .video, position: .back) else {
            LOG("Could not create camera device", level: .error)
            return
        }
        cameraActor = CameraActor(camera: videoDevice)
        await refreshStabilizations()
        await cameraActor?.startRunning()
    }
    func stopCamera() async {
        await cameraActor?.stopRunning()
        if let captureSession = await cameraActor?.getSession() {
            // Remove inputs
            for input in captureSession.inputs {
                captureSession.removeInput(input)
            }
            
            // Remove outputs
            for output in captureSession.outputs {
                captureSession.removeOutput(output)
            }
        }
        cameraActor = nil
    }
    func isRunning() async -> Bool {
        return await cameraActor?.isRunning() ?? false
    }
    func startOutput() async {
        await cameraActor?.startOutput()
    }
    func stopOutput() async {
        await cameraActor?.stopOutput()
    }
    func getAudioChannels() async -> [AVCaptureAudioChannel] {
        return await cameraActor?.getAudioChannels() ?? []
    }
    func setCameraStabilization(to stabilization: String) async {
        guard let stabilizationMode = stabilizations[stabilization] else {
            return
        }
        if await cameraActor?.setCameraStabilization(to: stabilizationMode) ?? false {
            LOG("Video stabilization \(stabilization)", level: .debug)
            UserDefaults.standard.set(stabilization, forKey: "CameraStabilization")
        }
    }
    func getCameraStabilization() async -> String {
        return await cameraActor?.getCameraStabilization() ?? "Off"
    }
    func setZoomFactor(_ zoomFactor: CGFloat) async {
        await cameraActor?.setZoomFactor(zoomFactor)
    }
    func getMinZoomFactor() async -> CGFloat {
        return await cameraActor?.getMinZoomFactor() ?? 1.0
    }
    func getMaxZoomFactor() async -> CGFloat {
        return await cameraActor?.getMaxZoomFactor() ?? 1.0
    }
    func getOpticalZoomFactor() async -> CGFloat {
        return await cameraActor?.getOpticalZoomFactor() ?? 1.0
    }
    func setFocus(at point: CGPoint) async {
        await cameraActor?.setFocus(at: point)
    }
    func setAutoFocus() async {
        await cameraActor?.setAutoFocus()
    }
    func setExposure(at point: CGPoint) async {
        await cameraActor?.setExposure(at: point)
    }
    func setAutoExposure() async {
        await cameraActor?.setAutoExposure()
    }
    
    func configurePreviewLayer(on viewController: UIViewController) async {
        await cameraActor?.configurePreviewLayer(on: viewController)
    }

}

@Observable
final class CameraMonitor: Sendable {
    public static let shared = CameraMonitor()
    private let cameraManager = CameraManager()

    func getStabilizations() async -> [String] {
        return await cameraManager.getStabilizations()
    }
    func getCameras() async -> [String] {
        return await cameraManager.getCameras()
    }
    func startCamera() async {
        await cameraManager.startCamera()
    }
    func stopCamera() async {
        await cameraManager.stopCamera()
    }
    func isRunning() async -> Bool {
        return await cameraManager.isRunning()
    }
    func startOutput() async {
        await cameraManager.startOutput()
    }
    func stopOutput() async {
        await cameraManager.stopOutput()
    }
    func getAudioChannels() async -> [AVCaptureAudioChannel] {
        return await cameraManager.getAudioChannels()
    }
    func setCameraStabilization(to stabilization: String) async {
        await cameraManager.setCameraStabilization(to: stabilization)
    }
    func getCameraStabilization() async -> String {
        return await cameraManager.getCameraStabilization()
    }
    func setZoomFactor(_ zoomFactor: CGFloat) async {
        await cameraManager.setZoomFactor(zoomFactor)
    }
    func getMinZoomFactor() async -> CGFloat {
        await cameraManager.getMinZoomFactor()
    }
    func getMaxZoomFactor() async -> CGFloat {
        await cameraManager.getMaxZoomFactor()
    }
    func getOpticalZoomFactor() async -> CGFloat {
        await cameraManager.getOpticalZoomFactor()
    }
    func setFocus(at point: CGPoint) async {
        await cameraManager.setFocus(at: point)
    }
    func setAutoFocus() async {
        await cameraManager.setAutoFocus()
    }
    func setExposure(at point: CGPoint) async {
        await cameraManager.setExposure(at: point)
    }
    func setAutoExposure() async {
        await cameraManager.setAutoExposure()
    }
    
    func configurePreviewLayer(on viewController: UIViewController) {
        Task {
            await cameraManager.configurePreviewLayer(on: viewController)
        }
    }

}



// Extend AVCaptureDevice to include findFormat method
extension AVCaptureDevice {
    func printFormatDetails(captureFormat: AVCaptureDevice.Format) {
        LOG("FormatID: \(captureFormat.formatDescription.mediaSubType.rawValue)", level: .debug)
        LOG("Supports \(captureFormat.formatDescription)", level: .debug)
        LOG("HDR: \(captureFormat.isVideoHDRSupported)", level: .debug)
        LOG("Frame range: \(captureFormat.videoSupportedFrameRateRanges)", level: .debug)
        LOG("Spatial video: \(captureFormat.isSpatialVideoCaptureSupported)", level: .debug)
        LOG("Background replacement: \(captureFormat.isBackgroundReplacementSupported)", level: .debug)
        LOG("Binned: \(captureFormat.isVideoBinned)", level: .debug)
        LOG("Multi-cam: \(captureFormat.isMultiCamSupported)", level: .debug)
        LOG("FOV: \(captureFormat.videoFieldOfView)", level: .debug)
        LOG("ISO: \(captureFormat.minISO) - \(captureFormat.maxISO)", level: .debug)
        LOG("Max zoom: \(captureFormat.videoMaxZoomFactor) (native zoom: \(captureFormat.secondaryNativeResolutionZoomFactors))", level: .debug)
        LOG("AF: \(captureFormat.autoFocusSystem)", level: .debug)
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
                    LOG("Desired format found", level: .info)
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
        Task {
            if await !cameraMonitor.isRunning() {
                await cameraMonitor.startCamera()
            }
            cameraMonitor.configurePreviewLayer(on: uiViewController)
        }
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


