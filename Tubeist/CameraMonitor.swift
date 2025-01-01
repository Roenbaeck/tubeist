//
//  CameraMonitor.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-04.
//

// @preconcurrency needed to pass previewLayer across boundary
@preconcurrency import AVFoundation
import SwiftUI
import AVKit

private actor CameraActor {
    private let cameraControlQueue = DispatchQueue(label: "com.subside.Tubeist.CameraControlQueue")
    private let session = AVCaptureSession()
    private let videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioDevice: AVCaptureDevice?
    private var audioInput: AVCaptureDeviceInput?
    private let audioOutput = AVCaptureAudioDataOutput()
    private var frameRate: Double
    private var minZoomFactor: CGFloat = 1.0
    private var maxZoomFactor: CGFloat = 1.0
    private var opticalZoomFactor: CGFloat = 1.0
    private var resolution: Resolution?
    
    private var totalZoom: Binding<Double>?
    private var currentZoom: Binding<Double>?
    
    // Had to add this to pass previewLayer across boundary
    nonisolated(unsafe) private let previewLayer: AVCaptureVideoPreviewLayer
    
    init(camera: AVCaptureDevice) {
        // Set all immutables
        previewLayer = AVCaptureVideoPreviewLayer(session: session)

        // Fetch frame rate from settings
        self.frameRate = Settings.selectedPreset?.frameRate ?? DEFAULT_FRAMERATE
        
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
            // configure session by adding inputs and outputs first
            session.beginConfiguration()
            // that's the only way I was able to get .inputPriority working
            session.sessionPreset = .inputPriority
            session.automaticallyConfiguresCaptureDeviceForWideColor = true
            session.configuresApplicationAudioSessionToMixWithOthers = true

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

            session.commitConfiguration()
            // only after the configuarion is commited, the following can be changed

            // videoDevice.listFormats()
            guard let format = videoDevice.findFormat() else {
                LOG("Desired format not found", level: .error)
                return
            }
            LOG("Found format:\n\(String(describing: format))")
            
            // Apply the format to the video device
            try videoDevice.lockForConfiguration()
            videoDevice.activeFormat = format
            videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(self.frameRate))
            videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(self.frameRate))
            videoDevice.activeColorSpace = AV_COLOR_SPACE
            videoDevice.unlockForConfiguration()
            
            self.minZoomFactor = videoDevice.minAvailableVideoZoomFactor
            self.maxZoomFactor = videoDevice.maxAvailableVideoZoomFactor
            self.opticalZoomFactor = videoDevice.activeFormat.secondaryNativeResolutionZoomFactors.first ?? 1.0
            self.resolution = Resolution(
                Int(videoDevice.activeFormat.formatDescription.dimensions.width),
                Int(videoDevice.activeFormat.formatDescription.dimensions.height)
            )

        } catch {
            LOG("Error setting up camera: \(error)", level: .error)
        }
//        LOG("Camera set up on thread: \(Thread.current)", level: .debug)
    }

    func bind(totalZoom: Binding<Double>, currentZoom: Binding<Double>) {
        self.totalZoom = totalZoom
        self.currentZoom = currentZoom
    }
    
    func addCameraControls() {
        if session.supportsControls {
            guard let videoDevice else { return }
            let zoomSlider = AVCaptureSystemZoomSlider(device: videoDevice) { zoomFactor in
                let displayZoom = videoDevice.displayVideoZoomFactorMultiplier * zoomFactor
                Task {
                    await self.setZoomFactor(displayZoom)
                    await self.totalZoom?.wrappedValue = displayZoom
                    await self.currentZoom?.wrappedValue = 0
                }
            }
            if session.canAddControl(zoomSlider) {
                LOG("Adding system zoom slider camera control", level: .debug)
                session.addControl(zoomSlider)
            }
            let exposureBiasSlider = AVCaptureSystemExposureBiasSlider(device: videoDevice) { exposureBias in
                // LOG("Setting exposure via slider: \(exposureBias)", level: .debug)
            }
            if session.canAddControl(exposureBiasSlider) {
                LOG("Adding system exposure bias slider camera control", level: .debug)
                session.addControl(exposureBiasSlider)
            }
            Task { @PipelineActor in
                await session.setControlsDelegate(CameraMonitor.shared, queue: cameraControlQueue)
            }
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
    
    func getCameraFrameRate() -> Double {
        return self.frameRate
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
    func autoFocus() {
        guard let device = videoDevice else { return }
        
        do {
            try device.lockForConfiguration()
            device.focusMode = .continuousAutoFocus
            device.unlockForConfiguration()
        } catch {
            LOG("Focus configuration error: \(error.localizedDescription)", level: .error)
        }
    }
    func lockFocus() {
        guard let device = videoDevice else { return }
        
        do {
            try device.lockForConfiguration()
            device.focusMode = .locked
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
    func autoExposure() {
        guard let device = videoDevice else { return }
        
        do {
            try device.lockForConfiguration()
            device.exposureMode = .continuousAutoExposure
            device.unlockForConfiguration()
        } catch {
            LOG("Exposure configuration error: \(error.localizedDescription)", level: .error)
        }
    }
    func lockExposure() {
        guard let device = videoDevice else { return }
        
        do {
            try device.lockForConfiguration()
            device.exposureMode = .locked
            device.unlockForConfiguration()
        } catch {
            LOG("Exposure configuration error: \(error.localizedDescription)", level: .error)
        }
    }

    func lockWhiteBalance() {
        guard let device = videoDevice else { return }
        
        do {
            try device.lockForConfiguration()
            device.whiteBalanceMode = .locked
            device.unlockForConfiguration()
        } catch {
            LOG("White balance configuration error: \(error.localizedDescription)", level: .error)
        }
    }
    func autoWhiteBalance() {
        guard let device = videoDevice else { return }

        do {
            try device.lockForConfiguration()
            device.whiteBalanceMode = .continuousAutoWhiteBalance
            device.unlockForConfiguration()
        } catch {
            LOG("White balance configuration error: \(error.localizedDescription)", level: .error)
        }
    }

    func startOutput() {
        Task { @PipelineActor in
            await videoOutput.setSampleBufferDelegate(FrameGrabber.shared, queue: PipelineActor.queue)
            await audioOutput.setSampleBufferDelegate(FrameGrabber.shared, queue: PipelineActor.queue)
        }
    }
    
    func stopOutput() {
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        audioOutput.setSampleBufferDelegate(nil, queue: nil)
    }
    
    func startRunning() {
        if !session.isRunning {
            LOG("Starting camera session", level: .debug)
            session.startRunning()
        }
    }
    
    func stopRunning() {
        if session.isRunning {
            LOG("Stopping camera session", level: .debug)
            session.stopRunning()
        }
    }
    
    func isRunning() -> Bool {
        session.isRunning
    }
    
    func getResolution() -> Resolution? {
        resolution
    }
    
    func getAudioChannels() -> [AVCaptureAudioChannel] {
        return audioOutput.connections.first?.audioChannels ?? []
    }
    
    func getSession() -> AVCaptureSession {
        session
    }

    func configurePreviewLayer(on viewController: UIViewController) {
        previewLayer.videoGravity = .resizeAspect
        
        if let connection = previewLayer.connection {
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
        }
        
        DispatchQueue.main.async {
            // Remove existing preview layers
            viewController.view.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            
            // Add preview layer
            viewController.view.layer.addSublayer(self.previewLayer)
            
            // Calculate the frame based on 16:9 ratio
            let height = viewController.view.bounds.height
            let width = height * (16.0/9.0)
            let x: CGFloat = 0
            let y: CGFloat = 0 
            
            CATransaction.begin()
            CATransaction.setAnimationDuration(0)
            self.previewLayer.frame = CGRect(x: x, y: y, width: width, height: height)
            CATransaction.commit()
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

    func bind(totalZoom: Binding<Double>, currentZoom: Binding<Double>) async {
        await cameraActor?.bind(totalZoom: totalZoom, currentZoom: currentZoom)
    }
    
    func getStabilizations() -> [String] {
        return Array(stabilizations.keys)
    }
    func getCameras() -> [String] {
        return Array(cameras.keys)
    }
    
    func startCamera() async {
        let camera = Settings.selectedCamera
        guard let cameraType = cameras[camera] else {
            LOG("Cannot find camera \(camera)", level: .error)
            return
        }
        guard let videoDevice = AVCaptureDevice.default(cameraType, for: .video, position: .back) else {
            LOG("Could not create camera device", level: .error)
            return
        }
        self.cameraActor = CameraActor(camera: videoDevice)
        guard let cameraActor = self.cameraActor else {
            LOG("Could not create camera actor", level: .error)
            return
        }
        await cameraActor.addCameraControls()
        self.stabilizations = await cameraActor.findSupportedStabilizationModes()
        let selectedStabilization = getCameraStabilization()
        await setCameraStabilization(to: selectedStabilization)
        await cameraActor.startRunning()
    }
    func stopCamera() async {
        guard let cameraActor = self.cameraActor else {
            LOG("Camera actor unavailable", level: .warning)
            return
        }
        await cameraActor.stopRunning()
        let captureSession = await cameraActor.getSession()
        // Remove inputs
        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }
        // Remove outputs
        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }
        self.cameraActor = nil
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
            Settings.cameraStabilization = stabilization
            LOG("Video stabilization set to \(stabilization)", level: .debug)
        }
    }
    func getCameraStabilization() -> String {
        return Settings.cameraStabilization ?? "Off"
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
    func autoFocus() async {
        await cameraActor?.autoFocus()
    }
    func lockFocus() async {
        await cameraActor?.lockFocus()
    }
    func setExposure(at point: CGPoint) async {
        await cameraActor?.setExposure(at: point)
    }
    func autoExposure() async {
        await cameraActor?.autoExposure()
    }
    func lockExposure() async {
        await cameraActor?.lockExposure()
    }
    func lockWhiteBalance() async {
        await cameraActor?.lockWhiteBalance()
    }
    func autoWhiteBalance() async {
        await cameraActor?.autoWhiteBalance()
    }
    func configurePreviewLayer(on viewController: UIViewController) async {
        await cameraActor?.configurePreviewLayer(on: viewController)
    }
    func getCameraFrameRate() async -> Double {
        await cameraActor?.getCameraFrameRate() ?? DEFAULT_FRAMERATE
    }
    func getResolution() async -> Resolution? {
        await cameraActor?.getResolution()
    }
}

final class CameraMonitor: NSObject, Sendable, AVCaptureSessionControlsDelegate {
    @PipelineActor public static let shared = CameraMonitor()
    private let cameraManager = CameraManager()
        
    func bind(totalZoom: Binding<Double>, currentZoom: Binding<Double>) async {
        await cameraManager.bind(totalZoom: totalZoom, currentZoom: currentZoom)
    }

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {
        return
    }
    
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        return
    }
    
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        return
    }
    
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        return
    }

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
    func autoFocus() async {
        await cameraManager.autoFocus()
    }
    func lockFocus() async {
        await cameraManager.lockFocus()
    }
    func setExposure(at point: CGPoint) async {
        await cameraManager.setExposure(at: point)
    }
    func autoExposure() async {
        await cameraManager.autoExposure()
    }
    func lockExposure() async {
        await cameraManager.lockExposure()
    }
    func lockWhiteBalance() async {
        await cameraManager.lockWhiteBalance()
    }
    func autoWhiteBalance() async {
        await cameraManager.autoWhiteBalance()
    }
    func getCameraFrameRate() async -> Double {
        await cameraManager.getCameraFrameRate()
    }
    func getResolution() async -> Resolution? {
        await cameraManager.getResolution()
    }
    func configurePreviewLayer(on viewController: UIViewController) {
        Task {
            await cameraManager.configurePreviewLayer(on: viewController)
        }
    }
    var frameRateLookup: [Resolution : Double] {
        var lookup: [Resolution : Double] = [:]
        guard let device = AVCaptureDevice.default(for: .video) else {
            return lookup
        }
        for format in device.formats {
            if format.isVideoHDRSupported {
                let dimensions = format.formatDescription.dimensions
                if dimensions.width * 9 == dimensions.height * 16 {
                    let resolution = Resolution(Int(dimensions.width), Int(dimensions.height))
                    for range in format.videoSupportedFrameRateRanges {
                        if range.maxFrameRate > lookup[resolution] ?? 0 {
                            lookup[resolution] = range.maxFrameRate
                        }
                    }
                }
            }
        }
        return lookup
    }
}


struct CaptureFormatCandidate {
    let width: Int
    let height: Int
    let frameRate: Double
    let format: AVCaptureDevice.Format
}

// Extend AVCaptureDevice to include findFormat method
extension AVCaptureDevice {
    func findFormat() -> AVCaptureDevice.Format? {
        let width = (Settings.isInputSyncedWithOutput ? Settings.selectedPreset?.width : DEFAULT_CAPTURE_WIDTH) ?? DEFAULT_CAPTURE_WIDTH
        let height = (Settings.isInputSyncedWithOutput ? Settings.selectedPreset?.height : DEFAULT_CAPTURE_HEIGHT) ?? DEFAULT_CAPTURE_HEIGHT
        let frameRate = Settings.selectedPreset?.frameRate ?? DEFAULT_FRAMERATE
        LOG("Searching for best capture format with resolution \(width)x\(height) and \(frameRate) FPS.")
        var candidates: [CaptureFormatCandidate] = []
        for captureFormat in formats {
            // Prefer 'x422' for HDR capture, since 4:2:2 gives the best possible color fidelity on current phones
            if captureFormat.formatDescription.mediaSubType.rawValue == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange {
                let description = captureFormat.formatDescription as CMFormatDescription
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                if dimensions.width >= width && dimensions.height >= height,
                   dimensions.width * 9 == dimensions.height * 16,
                   let frameRateRange = captureFormat.videoSupportedFrameRateRanges.first,
                   frameRateRange.maxFrameRate >= frameRate,
                   captureFormat.isVideoHDRSupported {
                    candidates.append(
                        CaptureFormatCandidate(
                            width: Int(dimensions.width),
                            height: Int(dimensions.height),
                            frameRate: frameRateRange.maxFrameRate,
                            format: captureFormat
                        )
                    )
                }
            }
        }
        if !candidates.isEmpty {
            LOG("Found \(candidates.count) 'x422' candidates")
            candidates.sort {
                if $0.width != $1.width {
                    return $0.width < $1.width          // Sort by width primarily
                } else {
                    return $0.frameRate < $1.frameRate  // Sort by frameRate secondarily if widths are equal
                }
            }
            return candidates.first?.format
        }
        for captureFormat in formats {
            // Fall back to 'x420' for HDR capture, which has less fidelity due to 4:2:0 chroma subsampling
            if captureFormat.formatDescription.mediaSubType.rawValue == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange {
                let description = captureFormat.formatDescription as CMFormatDescription
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                if dimensions.width >= width && dimensions.height >= height,
                   dimensions.width * 9 == dimensions.height * 16,
                   let frameRateRange = captureFormat.videoSupportedFrameRateRanges.first,
                   frameRateRange.maxFrameRate >= frameRate,
                   captureFormat.isVideoHDRSupported {
                    candidates.append(
                        CaptureFormatCandidate(
                            width: Int(dimensions.width),
                            height: Int(dimensions.height),
                            frameRate: frameRateRange.maxFrameRate,
                            format: captureFormat
                        )
                    )
                }
            }
        }
        if !candidates.isEmpty {
            LOG("Found \(candidates.count) 'x420' candidates")
            candidates.sort {
                if $0.width != $1.width {
                    return $0.width < $1.width          // Sort by width primarily
                } else {
                    return $0.frameRate < $1.frameRate  // Sort by frameRate secondarily if widths are equal
                }
            }
            return candidates.first?.format
        }
        return nil
    }
}

struct CameraMonitorView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let viewController = UIViewController()
        viewController.loadViewIfNeeded()
        return viewController
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        Task { @PipelineActor in
            CameraMonitor.shared.configurePreviewLayer(on: uiViewController)
        }
    }
}

struct CoreGraphicsAudioMeter: UIViewRepresentable {
    @Environment(AppState.self) var appState
    var width: CGFloat
    var height: CGFloat

    func makeUIView(context: Context) -> MeterView {
        let meterView = MeterView(width: width, height: height)
        return meterView
    }
    
    func updateUIView(_ uiView: MeterView, context: Context) {
        if appState.isAudioLevelRunning {
            uiView.startTimer()
        } else {
            uiView.stopTimer()
        }
        uiView.setNeedsDisplay() // Trigger redraw
    }
}

class MeterView: UIView {
    var width: CGFloat
    var height: CGFloat
    private var leftAverageLevel: Float = 0 { didSet { setNeedsDisplay() } }
    private var leftPeakLevel: Float = 0 { didSet { setNeedsDisplay() } }
    private var rightAverageLevel: Float = 0 { didSet { setNeedsDisplay() } }
    private var rightPeakLevel: Float = 0 { didSet { setNeedsDisplay() } }
    private var timer: Timer?

    init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
        super.init(frame: .zero)
        self.backgroundColor = UIColor.black.withAlphaComponent(0)
        startTimer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func startTimer() {
        guard let timer = self.timer else {
            self.timer = Timer.scheduledTimer(timeInterval: 0.04, target: self, selector: #selector(updateLevels), userInfo: nil, repeats: true)
            return
        }
        if !timer.isValid {
            self.timer = Timer.scheduledTimer(timeInterval: 0.04, target: self, selector: #selector(updateLevels), userInfo: nil, repeats: true)
        }
    }
    
    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func updateLevels() {
        Task { @MainActor in // Ensure UI updates on main thread
            let channels = await CameraMonitor.shared.getAudioChannels()
            if channels.count == 2 {
                leftAverageLevel = channels[0].averagePowerLevel
                leftPeakLevel = channels[0].peakHoldLevel
                rightAverageLevel = channels[1].averagePowerLevel
                rightPeakLevel = channels[1].peakHoldLevel
            } else if channels.count == 1 {
                leftAverageLevel = channels[0].averagePowerLevel
                leftPeakLevel = channels[0].peakHoldLevel
                rightAverageLevel = channels[0].averagePowerLevel
                rightPeakLevel = channels[0].peakHoldLevel
            }
        }
    }

    // Normalization function (adjust scaling as desired)
    private func normalizeLevel(_ level: Float) -> CGFloat {
        let normalizedLevel = max(0, level + 160) / 160  // Ensure level is in the 0-1 range
        let sigmoid = 1 / (1 + exp(-10 * (normalizedLevel - 0.95)))
        return CGFloat(sigmoid)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        let meterHeight = rect.height
        let halfWidth = rect.width / 2

        // Left Channel
        let leftPeakWidth = normalizeLevel(leftPeakLevel) * halfWidth
        let leftAverageWidth = normalizeLevel(leftAverageLevel) * halfWidth

        // Yellow (Peak) - Draw from right to left
        context.setFillColor(UIColor.green.withAlphaComponent(0.3).cgColor)
        context.fill(CGRect(x: halfWidth - leftPeakWidth, y: 0, width: leftPeakWidth, height: meterHeight))

        // Green (Average) - Draw from right to left
        context.setFillColor(UIColor.green.cgColor)
        context.fill(CGRect(x: halfWidth - leftAverageWidth, y: 0, width: leftAverageWidth, height: meterHeight))

        // Right Channel
        let rightPeakWidth = normalizeLevel(rightPeakLevel) * halfWidth
        let rightAverageWidth = normalizeLevel(rightAverageLevel) * halfWidth

        // Yellow (Peak) - Draw from left to right
        context.setFillColor(UIColor.green.withAlphaComponent(0.3).cgColor)
        context.fill(CGRect(x: halfWidth, y: 0, width: rightPeakWidth, height: meterHeight))

        // Green (Average) - Draw from left to right
        context.setFillColor(UIColor.green.cgColor)
        context.fill(CGRect(x: halfWidth, y: 0, width: rightAverageWidth, height: meterHeight))

        // Middle Line
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: halfWidth - 1, y: 0, width: 2, height: meterHeight))
    }
}


