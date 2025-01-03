//
//  CaptureDirector.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-04.
//

// @preconcurrency needed to suppress errors about non-Sendable instances
@preconcurrency import AVFoundation
import SwiftUI
import AVKit

@PipelineActor
private class MicrophoneActor {
    private var audioDevice: AVCaptureDevice?
    private var audioInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let setupLock = NSLock()

    // capabilties
    private let microphones: [String: AVCaptureDevice.DeviceType]

    init() {
        var microphoneDevicesByName: [String: AVCaptureDevice.DeviceType] = [:]
        
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
      
        for device in discoverySession.devices {
            let name = device.localizedName
            microphoneDevicesByName[name] = device.deviceType
        }
        
        microphones = microphoneDevicesByName
        LOG("Microphones: \(microphones.keys)", level: .debug)
    }
    
    func setup(microphoneType: AVCaptureDevice.DeviceType) {
        setupLock.lock()
        defer { setupLock.unlock() }

        guard let defaultAudioDevice = AVCaptureDevice.default(for: .audio) else {
            LOG("Could not create audio capture device", level: .error)
            return
        }

        let audioDevice: AVCaptureDevice
        if let selectedAudioDevice = AVCaptureDevice.default(microphoneType, for: .audio, position: .unspecified) {
            audioDevice = selectedAudioDevice
        }
        else {
            audioDevice = defaultAudioDevice
        }
        self.audioDevice = audioDevice

        // Configure the capture
        do {
            // configure session by adding inputs and outputs first
            CaptureDirector.audioSession.beginConfiguration()
            // that's the only way I was able to get .inputPriority working
            CaptureDirector.audioSession.sessionPreset = .inputPriority
            CaptureDirector.audioSession.configuresApplicationAudioSessionToMixWithOthers = true

            // set up audio
            self.audioInput = try AVCaptureDeviceInput(device: audioDevice)
            guard let audioInput = self.audioInput else {
                LOG("Could not create audio input", level: .error)
                return
            }
            self.audioOutput = AVCaptureAudioDataOutput()
            guard let audioOutput = self.audioOutput else {
                LOG("Could not create audio output", level: .error)
                return
            }
            // Add audio input to the session
            if CaptureDirector.audioSession.canAddInput(audioInput) {
                CaptureDirector.audioSession.addInput(audioInput)
            } else {
                LOG("Cannot add audio input", level: .error)
                return
            }
            // Add audio output to the session
            if CaptureDirector.audioSession.canAddOutput(audioOutput) {
                CaptureDirector.audioSession.addOutput(audioOutput)
            } else {
                LOG("Cannot add audio output", level: .error)
                return
            }

            CaptureDirector.audioSession.commitConfiguration()
            CaptureDirector.audioSession.startRunning()

        } catch {
            LOG("Error setting up microphone: \(error)", level: .error)
        }
        LOG("Microphone set up successfully", level: .info)
    }
    func startOutput() {
        guard let audioOutput = audioOutput else {
            LOG("Cannot start output, since audio is unavailable", level: .warning)
            return
        }
        audioOutput.setSampleBufferDelegate(SoundGrabber.shared, queue: PipelineActor.queue)
    }
    
    func stopOutput() {
        guard let audioOutput = audioOutput else {
            LOG("Cannot stop output, since audio is unavailable", level: .warning)
            return
        }
        audioOutput.setSampleBufferDelegate(nil, queue: nil)
    }
    
    func getMicrophones() -> [String] {
        return Array(microphones.keys)
    }
    func getMicrophoneType(_ microphone: String) -> AVCaptureDevice.DeviceType? {
        microphones[microphone]
    }

    func getAudioChannels() -> [AVCaptureAudioChannel] {
        guard let audioOutput = audioOutput,
              let channels = audioOutput.connections.first?.audioChannels else {
            return []
        }
        return channels
    }
}

@PipelineActor
private class CameraActor {
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var frameRate = DEFAULT_FRAMERATE
    private var minZoomFactor: CGFloat = 1.0
    private var maxZoomFactor: CGFloat = 1.0
    private var opticalZoomFactor: CGFloat = 1.0
    private var resolution = Resolution(DEFAULT_CAPTURE_WIDTH, DEFAULT_CAPTURE_HEIGHT)
    private let setupLock = NSLock()
    
    // UI bindings
    private var totalZoom: Binding<Double>?
    private var currentZoom: Binding<Double>?
    private var exposureBias: Binding<Float>?
    
    // capabilties
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

    func getStabilizations() -> [String] {
        return Array(stabilizations.keys)
    }
    func getStabilizationMode(_ stabilization: String) -> AVCaptureVideoStabilizationMode? {
        stabilizations[stabilization]
    }
    func getCameras() -> [String] {
        return Array(cameras.keys)
    }
    func getCameraType(_ camera: String) -> AVCaptureDevice.DeviceType? {
        cameras[camera]
    }
    func findSupportedStabilizationModes() {
        guard let format = videoDevice?.activeFormat else { return }
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
        stabilizations = supportedModes
    }
    
    func setup(cameraType: AVCaptureDevice.DeviceType) {
        setupLock.lock()
        defer { setupLock.unlock() }

        // Fetch frame rate from settings
        self.frameRate = Settings.selectedPreset?.frameRate ?? DEFAULT_FRAMERATE
        
        // Get devices
        guard let videoDevice = AVCaptureDevice.default(cameraType, for: .video, position: .back) else {
            LOG("Could not create video capture device", level: .error)
            return
        }
        self.videoDevice = videoDevice

        
        // Configure the capture
        do {
            // configure session by adding inputs and outputs first
            CaptureDirector.videoSession.beginConfiguration()
            // that's the only way I was able to get .inputPriority working
            CaptureDirector.videoSession.sessionPreset = .inputPriority
            CaptureDirector.videoSession.automaticallyConfiguresCaptureDeviceForWideColor = true

            // set up video
            self.videoInput = try AVCaptureDeviceInput(device: videoDevice)
            guard let videoInput = self.videoInput else {
                LOG("Could not create video input", level: .error)
                return
            }
            self.videoOutput = AVCaptureVideoDataOutput()
            guard let videoOutput = self.videoOutput else {
                LOG("Could not create video output", level: .error)
                return
            }
            // Add video input to the session
            if CaptureDirector.videoSession.canAddInput(videoInput) {
                CaptureDirector.videoSession.addInput(videoInput)
            } else {
                LOG("Cannot add video input", level: .error)
                return
            }
            // Add video output to the session
            if CaptureDirector.videoSession.canAddOutput(videoOutput) {
                CaptureDirector.videoSession.addOutput(videoOutput)
            } else {
                LOG("Cannot add video output", level: .error)
                return
            }

            CaptureDirector.videoSession.commitConfiguration()
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

            CaptureDirector.videoSession.startRunning()

        } catch {
            LOG("Error setting up camera: \(error)", level: .error)
        }
        LOG("Camera set up successfully", level: .info)
    }
    
    func bind(totalZoom: Binding<Double>, currentZoom: Binding<Double>, exposureBias: Binding<Float>) {
        self.totalZoom = totalZoom
        self.currentZoom = currentZoom
        self.exposureBias = exposureBias
    }
    
    func addCameraControls() {
        if CaptureDirector.videoSession.supportsControls {
            guard let videoDevice else { return }
            let zoomSlider = AVCaptureSystemZoomSlider(device: videoDevice) { zoomFactor in
                let displayZoom = videoDevice.displayVideoZoomFactorMultiplier * zoomFactor
                Task {
                    await self.setZoomFactor(displayZoom)
                    await self.totalZoom?.wrappedValue = displayZoom
                    await self.currentZoom?.wrappedValue = 0
                }
            }
            if CaptureDirector.videoSession.canAddControl(zoomSlider) {
                LOG("Adding system zoom slider camera control", level: .debug)
                CaptureDirector.videoSession.addControl(zoomSlider)
            }
            let exposureBiasSlider = AVCaptureSystemExposureBiasSlider(device: videoDevice) { exposureBias in
                Task {
                    await self.exposureBias?.wrappedValue = exposureBias
                }
            }
            if CaptureDirector.videoSession.canAddControl(exposureBiasSlider) {
                LOG("Adding system exposure bias slider camera control", level: .debug)
                CaptureDirector.videoSession.addControl(exposureBiasSlider)
            }
            Task { @PipelineActor in
                CaptureDirector.videoSession.setControlsDelegate(CaptureDirector.shared, queue: CAMERA_CONTROL_QUEUE)
            }
        }
    }
    
    func getCameraFrameRate() -> Double {
        return self.frameRate
    }
        
    func setCameraStabilization(to stabilization: AVCaptureVideoStabilizationMode) -> Bool {
        guard let videoOutput = videoOutput else {
            LOG("Cannot set stabilization on unconfigured video output", level: .warning)
            return false
        }
        // Find the video connection and enable stabilization
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                // Update the video stabilization mode on the connection.
                connection.preferredVideoStabilizationMode = stabilization
            } else {
                LOG("Video stabilization is not supported for this connection", level: .warning)
                return false
            }
        } else {
            LOG("Failed to get video connection", level: .error)
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
    func setLensPosition(to lensPosition: Float) {
        guard let device = videoDevice else { return }
        
        do {
            try device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: lensPosition)
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
    func setExposureBias(to bias: Float) {
        guard let device = videoDevice else { return }
        
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(bias)
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
        guard let videoOutput = videoOutput else {
            LOG("Cannot start output, since video is unavailable", level: .warning)
            return
        }
        videoOutput.setSampleBufferDelegate(FrameGrabber.shared, queue: PipelineActor.queue)
    }
    
    func stopOutput() {
        guard let videoOutput = videoOutput else {
            LOG("Cannot stop output, since video is unavailable", level: .warning)
            return
        }
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
    }
    func getResolution() -> Resolution? {
        resolution
    }
    
}

final class CaptureDirector: NSObject, Sendable, AVCaptureSessionControlsDelegate {
    @PipelineActor public static let shared = CaptureDirector()
    @PipelineActor public static let audioSession = AVCaptureSession()
    @PipelineActor public static let videoSession = AVCaptureSession()
    @PipelineActor private let cameraActor = CameraActor()
    @PipelineActor private let microphoneActor = MicrophoneActor()
    // minimal AVCaptureSessionControlsDelegate compliance
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) { return }
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) { return }
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) { return }
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) { return }

    func bind(totalZoom: Binding<Double>, currentZoom: Binding<Double>, exposureBias: Binding<Float>) async {
        await cameraActor.bind(totalZoom: totalZoom, currentZoom: currentZoom, exposureBias: exposureBias)
    }
    func getStabilizations() async -> [String] {
        return await cameraActor.getStabilizations()
    }
    func getCameras() async -> [String] {
        return await cameraActor.getCameras()
    }
    func cycleCamera() async {
        if await CaptureDirector.videoSession.isRunning {
            await detachCamera()
            await attachCamera()
        }
    }
    func attachCamera() async {
        // set up video session
        let camera = Settings.selectedCamera
        guard let cameraType = await cameraActor.getCameraType(camera) else {
            LOG("Cannot find camera \(camera)", level: .error)
            return
        }
        await cameraActor.setup(cameraType: cameraType)
        await cameraActor.addCameraControls()
        await cameraActor.findSupportedStabilizationModes()
        let selectedStabilization = Settings.cameraStabilization ?? "Off"
        await setCameraStabilization(to: selectedStabilization)
    }
    func detachCamera() async {
        await CaptureDirector.videoSession.stopRunning()
        for output in await CaptureDirector.videoSession.outputs {
            await CaptureDirector.videoSession.removeOutput(output)
        }
        for input in await CaptureDirector.videoSession.inputs {
            await CaptureDirector.videoSession.removeInput(input)
        }
    }
    func cycleMicrophone() async {
        if await CaptureDirector.audioSession.isRunning {
            await detachMicrophone()
            await attachMicrophone()
        }
    }
    func attachMicrophone() async {
        // set up audio session
        let microphone = DEFAULT_MICROPHONE
        guard let microphoneType = await microphoneActor.getMicrophoneType(microphone) else {
            LOG("Cannot find microphone \(microphone)", level: .error)
            return
        }
        await microphoneActor.setup(microphoneType: microphoneType)
    }
    func detachMicrophone() async {
        await CaptureDirector.audioSession.stopRunning()
        for output in await CaptureDirector.audioSession.outputs {
            await CaptureDirector.audioSession.removeOutput(output)
        }
        for input in await CaptureDirector.videoSession.inputs {
            await CaptureDirector.audioSession.removeInput(input)
        }
    }
    func startSessions() async {
        if await !isRunning() {
            await attachCamera()
            await attachMicrophone()
        }
    }
    func stopSessions() async {
        if await isRunning() {
            await detachMicrophone()
            await detachCamera()
        }
    }
    func isRunning() async -> Bool {
        let videoRunning = await CaptureDirector.videoSession.isRunning
        let audioRunning = await CaptureDirector.audioSession.isRunning
        return videoRunning && audioRunning
    }
    func startOutput() async {
        await cameraActor.startOutput()
        await microphoneActor.startOutput()
    }
    func stopOutput() async {
        await microphoneActor.stopOutput()
        await cameraActor.stopOutput()
    }
    func getAudioChannels() async -> [AVCaptureAudioChannel] {
        return await microphoneActor.getAudioChannels()
    }
    func setCameraStabilization(to stabilization: String) async {
        guard let stabilizationMode = await cameraActor.getStabilizationMode(stabilization) else {
            LOG("Unsupported stabilization mode \(stabilization)", level: .error)
            return
        }
        if await cameraActor.setCameraStabilization(to: stabilizationMode) {
            Settings.cameraStabilization = stabilization
            LOG("Video stabilization set to \(stabilization)", level: .debug)
        }
    }
    func setZoomFactor(_ zoomFactor: CGFloat) async {
        await cameraActor.setZoomFactor(zoomFactor)
    }
    func getMinZoomFactor() async -> CGFloat {
        await cameraActor.getMinZoomFactor()
    }
    func getMaxZoomFactor() async -> CGFloat {
        await cameraActor.getMaxZoomFactor()
    }
    func getOpticalZoomFactor() async -> CGFloat {
        await cameraActor.getOpticalZoomFactor()
    }
    func setFocus(at point: CGPoint) async {
        await cameraActor.setFocus(at: point)
    }
    func autoFocus() async {
        await cameraActor.autoFocus()
    }
    func lockFocus() async {
        await cameraActor.lockFocus()
    }
    func setLensPosition(to lensPosition: Float) async {
        await cameraActor.setLensPosition(to: lensPosition)
    }
    func setExposure(at point: CGPoint) async {
        await cameraActor.setExposure(at: point)
    }
    func autoExposure() async {
        await cameraActor.autoExposure()
    }
    func lockExposure() async {
        await cameraActor.lockExposure()
    }
    func setExposureBias(to bias: Float) async {
        await cameraActor.setExposureBias(to: bias)
    }
    func lockWhiteBalance() async {
        await cameraActor.lockWhiteBalance()
    }
    func autoWhiteBalance() async {
        await cameraActor.autoWhiteBalance()
    }
    func getCameraFrameRate() async -> Double {
        await cameraActor.getCameraFrameRate()
    }
    func getResolution() async -> Resolution? {
        await cameraActor.getResolution()
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





