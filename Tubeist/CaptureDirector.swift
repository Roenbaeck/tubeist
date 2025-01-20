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
private class DeviceActor {
    // video device
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var frameRate = DEFAULT_FRAMERATE
    private var minZoomFactor: CGFloat = 1.0
    private var maxZoomFactor: CGFloat = 1.0
    private var opticalZoomFactor: CGFloat = 1.0
    private var resolution = Resolution(DEFAULT_CAPTURE_WIDTH, DEFAULT_CAPTURE_HEIGHT)
    // audio device
    private var audioDevice: AVCaptureDevice?
    private var audioInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?
    // UI bindings
    private var totalZoom: Binding<Double>?
    private var currentZoom: Binding<Double>?
    private var exposureBias: Binding<Float>?
    private var style: Binding<String>?
    private var effect: Binding<String>?
    // capabilties
    private let cameras: [String: AVCaptureDevice.DeviceType]
    private let microphones: [String: AVCaptureDevice.DeviceType]
    private var stabilizations: [String: AVCaptureVideoStabilizationMode] = [:]
    // guards
    private let setupLock = NSLock()

    init() {
        var cameraDevicesByName: [String: AVCaptureDevice.DeviceType] = [:]
        
        let cameraDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInTelephotoCamera,
                .builtInTripleCamera
            ],
            mediaType: .video,
            position: .back
        )
      
        for device in cameraDiscoverySession.devices {
            let name = device.localizedName
            cameraDevicesByName[name] = device.deviceType
        }
        
        cameras = cameraDevicesByName
        LOG("Cameras: \(cameras.keys)", level: .debug)
        
        var microphoneDevicesByName: [String: AVCaptureDevice.DeviceType] = [:]
        
        let microphoneDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
      
        for device in microphoneDiscoverySession.devices {
            let name = device.localizedName
            microphoneDevicesByName[name] = device.deviceType
        }
        
        microphones = microphoneDevicesByName
        LOG("Microphones: \(microphones.keys)", level: .debug)
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
    
    func setup(cameraType: AVCaptureDevice.DeviceType, microphoneType: AVCaptureDevice.DeviceType, session: AVCaptureSession) {
        setupLock.lock()
        defer { setupLock.unlock() }

        // Fetch frame rate from settings
        self.frameRate = Settings.selectedPreset.frameRate
        
        // Get devices
        guard let videoDevice = AVCaptureDevice.default(cameraType, for: .video, position: .back) else {
            LOG("Could not create video capture device", level: .error)
            return
        }
        self.videoDevice = videoDevice
        
        guard let defaultAudioDevice = AVCaptureDevice.default(for: .audio) else {
            LOG("Could not create audio capture device", level: .error)
            return
        }

        let audioDevice: AVCaptureDevice
        if let selectedAudioDevice = AVCaptureDevice.default(microphoneType, for: .audio, position: .unspecified) {
            LOG("Using selected microphone: \(selectedAudioDevice.localizedName)", level: .debug)
            audioDevice = selectedAudioDevice
        }
        else {
            audioDevice = defaultAudioDevice
        }
        self.audioDevice = audioDevice
        
        // Configure the capture
        do {
            // configure session by adding inputs and outputs first
            session.beginConfiguration()
            // that's the only way I was able to get .inputPriority working
            session.sessionPreset = .inputPriority
            session.automaticallyConfiguresCaptureDeviceForWideColor = true

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
            
            session.automaticallyConfiguresApplicationAudioSession = false

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

            do {
                try AVAudioSession.sharedInstance().setCategory(
                    .playAndRecord,
                    mode: .videoRecording,
                    options: [.mixWithOthers, .overrideMutedMicrophoneInterruption])
                try AVAudioSession.sharedInstance().setPreferredSampleRate(AUDIO_SAMPLE_RATE)
                try AVAudioSession.sharedInstance().setActive(true)
            }
            catch {
                LOG("Could not set up the app audio session: \(error.localizedDescription)", level: .error)
            }
            
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
            LOG("Error setting up devices: \(error)", level: .error)
        }
        LOG("Devices set up successfully", level: .info)
    }
    
    func bind(totalZoom: Binding<Double>, currentZoom: Binding<Double>, exposureBias: Binding<Float>, style: Binding<String>, effect: Binding<String>) {
        self.totalZoom = totalZoom
        self.currentZoom = currentZoom
        self.exposureBias = exposureBias
        self.style = style
        self.effect = effect
    }
    
    func addCameraControls(session: AVCaptureSession) {
        if session.supportsControls {
            // remove controls so they don't get added over and over
            session.controls.forEach({ session.removeControl($0) })
            
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
                Task {
                    await self.exposureBias?.wrappedValue = exposureBias
                }
            }
            if session.canAddControl(exposureBiasSlider) {
                LOG("Adding system exposure bias slider camera control", level: .debug)
                session.addControl(exposureBiasSlider)
            }
            
            // custom controls must be added in a nonisolated context
            Task {
                if await Purchaser.shared.isProductPurchased("tubeist_lifetime_styling") {
                    addCustomCameraControls(to: session)
                }
            }
            
            Task { @PipelineActor in
                session.setControlsDelegate(CaptureDirector.shared, queue: CAMERA_CONTROL_QUEUE)
            }
        }
    }
    
    nonisolated func addCustomCameraControls(to session: AVCaptureSession) {
        // styles
        let stylePicker = AVCaptureIndexPicker(
            "Style",
            symbolName: "camera.filters",
            localizedIndexTitles: AVAILABLE_STYLES
        )
        stylePicker.setActionQueue(CAMERA_CONTROL_QUEUE) { index in
            let style = AVAILABLE_STYLES[index]
            Settings.style = style
            Task {
                await self.style?.wrappedValue = style
                await FrameGrabber.shared.refreshStyle()
            }
        }
        if session.canAddControl(stylePicker) {
            LOG("Adding style picker camera control", level: .debug)
            session.addControl(stylePicker)
            // the picker is very picky on being accessed on its designated queue
            CAMERA_CONTROL_QUEUE.async {
                let selectedIndex = AVAILABLE_STYLES.firstIndex(of: Settings.style ?? NO_STYLE) ?? 0
                stylePicker.selectedIndex = selectedIndex
            }
        }
        // effects
        let effectPicker = AVCaptureIndexPicker(
            "Effect",
            symbolName: "circle.bottomrighthalf.pattern.checkered",
            localizedIndexTitles: AVAILABLE_EFFECTS
        )
        effectPicker.setActionQueue(CAMERA_CONTROL_QUEUE) { index in
            let effect = AVAILABLE_EFFECTS[index]
            Settings.effect = effect
            Task {
                await self.effect?.wrappedValue = effect
                await FrameGrabber.shared.refreshEffect()
            }
        }
        if session.canAddControl(effectPicker) {
            LOG("Adding effect picker camera control", level: .debug)
            session.addControl(effectPicker)
            // the picker is very picky on being accessed on its designated queue
            CAMERA_CONTROL_QUEUE.async {
                let selectedIndex = AVAILABLE_EFFECTS.firstIndex(of: Settings.effect ?? NO_EFFECT) ?? 0
                effectPicker.selectedIndex = selectedIndex
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

    func startVideoOutput() {
        guard let videoOutput = videoOutput else {
            LOG("Cannot start output, since video is unavailable", level: .warning)
            return
        }
        videoOutput.setSampleBufferDelegate(FrameGrabber.shared, queue: PipelineActor.queue)
        LOG("Starting video output", level: .debug)
    }
    
    func stopVideoOutput() {
        guard let videoOutput = videoOutput else {
            LOG("Cannot stop output, since video is unavailable", level: .warning)
            return
        }
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        LOG("Stopping video output", level: .debug)
    }
    func getResolution() -> Resolution? {
        resolution
    }

    func startAudioOutput() {
        guard let audioOutput = audioOutput else {
            LOG("Cannot start output, since audio is unavailable", level: .warning)
            return
        }
        if audioOutput.sampleBufferDelegate == nil {
            audioOutput.setSampleBufferDelegate(SoundGrabber.shared, queue: PipelineActor.queue)
            LOG("Starting audio output", level: .debug)
        }
        else {
            LOG("Audio output already started", level: .debug)
        }
    }
    
    func stopAudioOutput() {
        guard let audioOutput = audioOutput else {
            LOG("Cannot stop output, since audio is unavailable", level: .warning)
            return
        }
        if audioOutput.sampleBufferDelegate != nil {
            audioOutput.setSampleBufferDelegate(nil, queue: nil)
            LOG("Stopping audio output", level: .debug)
        }
        else {
            LOG("Audio output already stopped", level: .debug)
        }
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

extension CaptureDirector: AVCaptureSessionControlsDelegate {
    // minimal AVCaptureSessionControlsDelegate compliance
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) { return }
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) { return }
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) { return }
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) { return }
}

final class CaptureDirector: NSObject, Sendable {
    @PipelineActor public static let shared = CaptureDirector()
    @PipelineActor private let session = AVCaptureSession()
    @PipelineActor private let deviceActor = DeviceActor()

    func bind(totalZoom: Binding<Double>, currentZoom: Binding<Double>, exposureBias: Binding<Float>, style: Binding<String>, effect: Binding<String>) async {
        await deviceActor.bind(totalZoom: totalZoom, currentZoom: currentZoom, exposureBias: exposureBias, style: style, effect: effect)
    }
    func getStabilizations() async -> [String] {
        return await deviceActor.getStabilizations()
    }
    func getCameras() async -> [String] {
        return await deviceActor.getCameras()
    }
    func getSession() async -> AVCaptureSession {
        await session
    }
    func getSessionTime() async -> CMTime? {
        await session.synchronizationClock?.time
    }
    func cycleSession() async {
        if await session.isRunning {
            await session.stopRunning()
            await detachAll()
            await attachAll()
            await session.startRunning()
        }
    }
    func detachAll() async {
        for output in await session.outputs {
            await session.removeOutput(output)
        }
        for input in await session.inputs {
            await session.removeInput(input)
        }
    }
    func attachAll() async {
        // set up video and audio session
        let camera = Settings.selectedCamera
        guard let cameraType = await deviceActor.getCameraType(camera) else {
            LOG("Cannot find camera \(camera)", level: .error)
            return
        }
        let microphone = DEFAULT_MICROPHONE
        guard let microphoneType = await deviceActor.getMicrophoneType(microphone) else {
            LOG("Cannot find microphone \(microphone)", level: .error)
            return
        }

        await deviceActor.setup(cameraType: cameraType, microphoneType: microphoneType, session: session)
        await deviceActor.addCameraControls(session: session)
        await deviceActor.findSupportedStabilizationModes()
        let selectedStabilization = Settings.cameraStabilization ?? "Off"
        await setCameraStabilization(to: selectedStabilization)
    }
    func startSessions() async {
        if await !isRunning() {
            await attachAll()
            await session.startRunning()
        }
    }
    func stopSessions() async {
        if await isRunning() {
            await session.stopRunning()
            await detachAll()
        }
    }
    func isRunning() async -> Bool {
        await session.isRunning
    }
    func startOutput() async {
        await deviceActor.startAudioOutput() // start audio first, to ensure we get audio samples with the video
        await deviceActor.startVideoOutput()
    }
    func stopOutput() async {
        await deviceActor.stopVideoOutput()
        await deviceActor.stopAudioOutput()
    }
    func getAudioChannels() async -> [AVCaptureAudioChannel] {
        return await deviceActor.getAudioChannels()
    }
    func setCameraStabilization(to stabilization: String) async {
        guard let stabilizationMode = await deviceActor.getStabilizationMode(stabilization) else {
            LOG("Unsupported stabilization mode \(stabilization)", level: .error)
            return
        }
        if await deviceActor.setCameraStabilization(to: stabilizationMode) {
            Settings.cameraStabilization = stabilization
            LOG("Video stabilization set to \(stabilization)", level: .debug)
        }
    }
    func setZoomFactor(_ zoomFactor: CGFloat) async {
        await deviceActor.setZoomFactor(zoomFactor)
    }
    func getMinZoomFactor() async -> CGFloat {
        await deviceActor.getMinZoomFactor()
    }
    func getMaxZoomFactor() async -> CGFloat {
        await deviceActor.getMaxZoomFactor()
    }
    func getOpticalZoomFactor() async -> CGFloat {
        await deviceActor.getOpticalZoomFactor()
    }
    func setFocus(at point: CGPoint) async {
        await deviceActor.setFocus(at: point)
    }
    func autoFocus() async {
        await deviceActor.autoFocus()
    }
    func lockFocus() async {
        await deviceActor.lockFocus()
    }
    func setLensPosition(to lensPosition: Float) async {
        await deviceActor.setLensPosition(to: lensPosition)
    }
    func setExposure(at point: CGPoint) async {
        await deviceActor.setExposure(at: point)
    }
    func autoExposure() async {
        await deviceActor.autoExposure()
    }
    func lockExposure() async {
        await deviceActor.lockExposure()
    }
    func setExposureBias(to bias: Float) async {
        await deviceActor.setExposureBias(to: bias)
    }
    func lockWhiteBalance() async {
        await deviceActor.lockWhiteBalance()
    }
    func autoWhiteBalance() async {
        await deviceActor.autoWhiteBalance()
    }
    func getCameraFrameRate() async -> Double {
        await deviceActor.getCameraFrameRate()
    }
    func getResolution() async -> Resolution? {
        await deviceActor.getResolution()
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
        let width = (Settings.isInputSyncedWithOutput ? Settings.selectedPreset.width : DEFAULT_CAPTURE_WIDTH)
        let height = (Settings.isInputSyncedWithOutput ? Settings.selectedPreset.height : DEFAULT_CAPTURE_HEIGHT)
        let frameRate = Settings.selectedPreset.frameRate 
        LOG("Searching for best capture format with resolution \(width)x\(height) and \(frameRate) FPS.")
        var candidates: [CaptureFormatCandidate] = []
        let pixelFormats = [
            // Prefer 'x422' for HDR capture, since 4:2:2 gives the best possible color fidelity on current phones
            kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
            kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            // Fall back to 'x420' for HDR capture, which has less fidelity due to 4:2:0 chroma subsampling
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ]
        for pixelFormat in pixelFormats {
            for captureFormat in formats {
                if captureFormat.formatDescription.mediaSubType.rawValue == pixelFormat {
                    let description = captureFormat.formatDescription as CMFormatDescription
                    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                    if dimensions.width >= width && dimensions.height >= height,
                       dimensions.width * 9 == dimensions.height * 16,
                       let frameRateRange = captureFormat.videoSupportedFrameRateRanges.first,
                       frameRateRange.maxFrameRate >= frameRate,
                       captureFormat.supportedColorSpaces.contains(AV_COLOR_SPACE) {
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
                LOG("Found \(candidates.count) pixel format candidates")
                candidates.sort {
                    if $0.width != $1.width {
                        return $0.width < $1.width          // Sort by width primarily
                    } else {
                        return $0.frameRate < $1.frameRate  // Sort by frameRate secondarily if widths are equal
                    }
                }
                return candidates.first?.format
            }
        }
        return nil
    }
}





