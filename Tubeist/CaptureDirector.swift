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

#if canImport(AVFoundation)
extension AVCaptureAudioChannel: @retroactive @unchecked Sendable {}
#endif

enum CaptureSetupError: LocalizedError, Equatable {
    case controlInProgress
    case noCamera
    case noMicrophone
    case videoDeviceUnavailable
    case formatUnavailable
    case cannotAddVideoInput
    case cannotAddVideoOutput
    case cannotAddAudioInput
    case cannotAddAudioOutput
    case videoOutputUnavailable
    case audioOutputUnavailable
    case configuration(String)
    case audioSession(String)
    case sessionDidNotStart

    var errorDescription: String? {
        switch self {
        case .controlInProgress: "Camera configuration is already in progress"
        case .noCamera: "No compatible camera is available"
        case .noMicrophone: "No compatible microphone is available"
        case .videoDeviceUnavailable: "The selected camera is unavailable"
        case .formatUnavailable: "The selected camera does not support the requested HDR format"
        case .cannotAddVideoInput: "The camera input cannot be added to the capture session"
        case .cannotAddVideoOutput: "The video output cannot be added to the capture session"
        case .cannotAddAudioInput: "The microphone input cannot be added to the capture session"
        case .cannotAddAudioOutput: "The audio output cannot be added to the capture session"
        case .videoOutputUnavailable: "The video output is not configured"
        case .audioOutputUnavailable: "The audio output is not configured"
        case .configuration(let message): "Camera configuration failed: \(message)"
        case .audioSession(let message): "Microphone session configuration failed: \(message)"
        case .sessionDidNotStart: "The camera session did not start"
        }
    }
}

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
    private var cameras: [String: String]
    private var microphones: [String: String]
    private var stabilizations: [String: AVCaptureVideoStabilizationMode] = [:]
    // states
    private var isOutputting: Bool = false
    
    func setOutputting(_ isOutputting: Bool) {
        self.isOutputting = isOutputting
    }
    func getOutputting() -> Bool {
        return self.isOutputting
    }

    init() {
        cameras = Self.discoverCameras()
        microphones = Self.discoverMicrophones()
        LOG("Cameras: \(cameras.keys)", level: .info)
        LOG("Microphones: \(microphones.keys)", level: .info)
    }

    func getStabilizations() -> [String] {
        return Array(stabilizations.keys)
    }
    func getStabilizationMode(_ stabilization: String) -> AVCaptureVideoStabilizationMode? {
        stabilizations[stabilization]
    }
    func getCameras() -> [String] {
        refreshDevices()
        return Array(cameras.keys)
    }
    func getCameraID(_ camera: String) -> String? {
        cameras[camera]
    }
    func getCameraName(_ cameraID: String) -> String? {
        cameras.first { $0.value == cameraID }?.key
    }
    func getFirstCameraName() -> String? {
        cameras.keys.first
    }
    func getFirstCameraID() -> String? {
        return cameras.values.first
    }

    func frameRateLookup(for camera: String) -> [Resolution: Double] {
        guard let cameraID = cameras[camera], let device = AVCaptureDevice(uniqueID: cameraID) else {
            return [:]
        }
        var lookup: [Resolution: Double] = [:]
        for format in device.formats where format.isVideoHDRSupported {
            let dimensions = format.formatDescription.dimensions
            guard dimensions.width * 9 == dimensions.height * 16 else { continue }
            let resolution = Resolution(Int(dimensions.width), Int(dimensions.height))
            for range in format.videoSupportedFrameRateRanges where range.maxFrameRate > lookup[resolution] ?? 0 {
                lookup[resolution] = range.maxFrameRate
            }
        }
        return lookup
    }

    private func refreshDevices() {
        cameras = Self.discoverCameras()
        microphones = Self.discoverMicrophones()
        LOG("Cameras: \(cameras.keys)", level: .info)
        LOG("Microphones: \(microphones.keys)", level: .info)
    }

    private static func discoverCameras() -> [String: String] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTelephotoCamera, .builtInTripleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return devicesByDisplayName(discovery.devices)
    }

    private static func discoverMicrophones() -> [String: String] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return devicesByDisplayName(discovery.devices)
    }

    private static func devicesByDisplayName(_ devices: [AVCaptureDevice]) -> [String: String] {
        var result: [String: String] = [:]
        for device in devices {
            var displayName = device.localizedName
            if result[displayName] != nil {
                displayName += " (\(device.uniqueID.suffix(6)))"
            }
            result[displayName] = device.uniqueID
        }
        return result
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
    
    func setup(cameraDevice videoDevice: AVCaptureDevice, microphoneDevice: AVCaptureDevice, session: AVCaptureSession) throws {
        // Fetch frame rate from settings
        self.frameRate = Settings.selectedPreset.frameRate

        guard let format = videoDevice.findFormat() else {
            throw CaptureSetupError.formatUnavailable
        }

        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            let videoOutput = AVCaptureVideoDataOutput()
            let audioInput = try AVCaptureDeviceInput(device: microphoneDevice)
            let audioOutput = AVCaptureAudioDataOutput()

            try videoDevice.lockForConfiguration()
            videoDevice.activeFormat = format
            videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            videoDevice.activeColorSpace = AV_COLOR_SPACE
            videoDevice.unlockForConfiguration()
            videoOutput.alwaysDiscardsLateVideoFrames = true

            session.beginConfiguration()
            session.sessionPreset = .inputPriority
            session.automaticallyConfiguresCaptureDeviceForWideColor = true
            session.automaticallyConfiguresApplicationAudioSession = false
            var addedInputs: [AVCaptureInput] = []
            var addedOutputs: [AVCaptureOutput] = []
            do {
                guard session.canAddInput(videoInput) else { throw CaptureSetupError.cannotAddVideoInput }
                session.addInput(videoInput)
                addedInputs.append(videoInput)
                guard session.canAddOutput(videoOutput) else { throw CaptureSetupError.cannotAddVideoOutput }
                session.addOutput(videoOutput)
                addedOutputs.append(videoOutput)
                guard session.canAddInput(audioInput) else { throw CaptureSetupError.cannotAddAudioInput }
                session.addInput(audioInput)
                addedInputs.append(audioInput)
                guard session.canAddOutput(audioOutput) else { throw CaptureSetupError.cannotAddAudioOutput }
                session.addOutput(audioOutput)
                addedOutputs.append(audioOutput)
                session.commitConfiguration()
            } catch {
                for output in addedOutputs { session.removeOutput(output) }
                for input in addedInputs { session.removeInput(input) }
                session.commitConfiguration()
                throw error
            }

            do {
                try AVAudioSession.sharedInstance().setCategory(
                    .playAndRecord,
                    mode: .videoRecording,
                    options: [.mixWithOthers, .overrideMutedMicrophoneInterruption]
                )
                try AVAudioSession.sharedInstance().setPreferredSampleRate(AUDIO_SAMPLE_RATE)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                throw CaptureSetupError.audioSession(error.localizedDescription)
            }

            self.videoDevice = videoDevice
            self.videoInput = videoInput
            self.videoOutput = videoOutput
            self.audioDevice = microphoneDevice
            self.audioInput = audioInput
            self.audioOutput = audioOutput
            minZoomFactor = videoDevice.minAvailableVideoZoomFactor
            maxZoomFactor = videoDevice.maxAvailableVideoZoomFactor
            opticalZoomFactor = videoDevice.activeFormat.secondaryNativeResolutionZoomFactors.first ?? 1.0
            resolution = Resolution(
                Int(videoDevice.activeFormat.formatDescription.dimensions.width),
                Int(videoDevice.activeFormat.formatDescription.dimensions.height)
            )
            LOG("Found format:\n\(String(describing: format))", level: .debug)
            LOG("Devices set up successfully", level: .info)
        } catch let error as CaptureSetupError {
            throw error
        } catch {
            throw CaptureSetupError.configuration(error.localizedDescription)
        }
    }
    
    func bind(totalZoom: Binding<Double>, currentZoom: Binding<Double>, exposureBias: Binding<Float>, style: Binding<String>, effect: Binding<String>) {
        self.totalZoom = totalZoom
        self.currentZoom = currentZoom
        self.exposureBias = exposureBias
        self.style = style
        self.effect = effect
    }
    
    func addCameraControls(session: AVCaptureSession) async {
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
            if await Purchaser.shared.isProductPurchased("tubeist_lifetime_styling") {
                self.addCustomCameraControls(to: session)
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
            Task { @PipelineActor in
                self.style?.wrappedValue = style
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
            Task { @PipelineActor in
                self.effect?.wrappedValue = effect
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

    func startVideoOutput() throws {
        guard let videoOutput = videoOutput else {
            throw CaptureSetupError.videoOutputUnavailable
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

    func startAudioOutput() throws {
        guard let audioOutput = audioOutput else {
            throw CaptureSetupError.audioOutputUnavailable
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
    func getMicrophoneID(_ microphone: String) -> String? {
        microphones[microphone]
    }
    func getMicrophoneName(_ microphoneID: String) -> String? {
        microphones.first { $0.value == microphoneID }?.key
    }
    func getPreferredMicrophoneID() -> String? {
        AVCaptureDevice.default(for: .audio)?.uniqueID
    }
    func getPreferredMicrophoneName() -> String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }
    func getFirstMicrophoneName() -> String? {
        microphones.keys.first
    }
    func getFirstMicrophoneID() -> String? {
        microphones.values.first
    }

    func getAudioChannels() -> [AVCaptureAudioChannel] {
        guard let audioOutput = audioOutput,
              let channels = audioOutput.connections.first?.audioChannels else {
            return []
        }
        return channels
    }

}

actor SessionController {
    private var isControllingSession = false
    private var session: AVCaptureSession
    
    init(session: AVCaptureSession) {
        self.session = session
    }
    
    func startSessions() async throws {
        guard !isControllingSession else { throw CaptureSetupError.controlInProgress }
        
        isControllingSession = true
        defer { isControllingSession = false }
        
        if !session.isRunning {
            do {
                try await CaptureDirector.shared.attachAll()
                session.startRunning()
                guard session.isRunning else {
                    throw CaptureSetupError.sessionDidNotStart
                }
            } catch {
                await CaptureDirector.shared.detachAll()
                throw error
            }
        }
    }
    
    func stopSessions() async {
        guard !isControllingSession else { return }
        
        isControllingSession = true
        defer { isControllingSession = false }
        
        if session.isRunning {
            session.stopRunning()
            await CaptureDirector.shared.detachAll()
        }
    }
    
    func cycleSessions() async throws {
        guard !isControllingSession else { throw CaptureSetupError.controlInProgress }
        
        isControllingSession = true
        defer { isControllingSession = false }
        
        if session.isRunning {
            session.stopRunning()
            await CaptureDirector.shared.detachAll()
        }
        if !session.isRunning {
            do {
                try await CaptureDirector.shared.attachAll()
                session.startRunning()
                guard session.isRunning else {
                    throw CaptureSetupError.sessionDidNotStart
                }
            } catch {
                await CaptureDirector.shared.detachAll()
                throw error
            }
        }
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
    @PipelineActor private static let session = AVCaptureSession()
    @PipelineActor private let deviceActor = DeviceActor()
    @PipelineActor private let sessionController = SessionController(session: CaptureDirector.session)
    private let eventMonitor = CaptureEventMonitor()

    func bind(totalZoom: Binding<Double>, currentZoom: Binding<Double>, exposureBias: Binding<Float>, style: Binding<String>, effect: Binding<String>) async {
        await deviceActor.bind(totalZoom: totalZoom, currentZoom: currentZoom, exposureBias: exposureBias, style: style, effect: effect)
    }
    func getStabilizations() async -> [String] {
        return await deviceActor.getStabilizations()
    }
    func getCameras() async -> [String] {
        return await deviceActor.getCameras()
    }
    func getMicrophones() async -> [String] {
        return await deviceActor.getMicrophones()
    }
    func getPreferredMicrophoneName() async -> String? {
        return await deviceActor.getPreferredMicrophoneName()
    }
    func selectCamera(named camera: String) async -> Bool {
        guard let cameraID = await deviceActor.getCameraID(camera) else { return false }
        Settings.selectedCamera = camera
        Settings.selectedCameraID = cameraID
        return true
    }
    func selectMicrophone(named microphone: String) async -> Bool {
        guard let microphoneID = await deviceActor.getMicrophoneID(microphone) else { return false }
        Settings.selectedMicrophone = microphone
        Settings.selectedMicrophoneID = microphoneID
        return true
    }
    func getSession() async -> AVCaptureSession {
        await CaptureDirector.session
    }
    func getSessionTime() async -> CMTime? {
        await CaptureDirector.session.synchronizationClock?.time
    }
    func detachAll() async {
        await CaptureDirector.session.beginConfiguration()
        for output in await CaptureDirector.session.outputs {
            await CaptureDirector.session.removeOutput(output)
        }
        for input in await CaptureDirector.session.inputs {
            await CaptureDirector.session.removeInput(input)
        }
        await CaptureDirector.session.commitConfiguration()
    }
    func attachAll() async throws {
        // set up video and audio session
        _ = await deviceActor.getCameras()
        let camera = Settings.selectedCamera
        var resolvedCamera = camera
        var cameraID = Settings.selectedCameraID.flatMap { savedID in
            AVCaptureDevice(uniqueID: savedID) == nil ? nil : savedID
        }
        if let cameraID, let currentName = await deviceActor.getCameraName(cameraID) {
            resolvedCamera = currentName
        } else {
            cameraID = await deviceActor.getCameraID(camera)
        }
        if cameraID == nil {
            LOG("Cannot find designated camera \(camera), using first available camera", level: .warning)
            if await deviceActor.getCameraID(DEFAULT_CAMERA) != nil {
                resolvedCamera = DEFAULT_CAMERA
                cameraID = await deviceActor.getCameraID(DEFAULT_CAMERA)
            }
            else if let firstCamera = await deviceActor.getFirstCameraName() {
                resolvedCamera = firstCamera
                cameraID = await deviceActor.getCameraID(firstCamera)
            }
        }
        guard let cameraID, let cameraDevice = AVCaptureDevice(uniqueID: cameraID) else {
            throw CaptureSetupError.noCamera
        }
        if Settings.selectedCamera != resolvedCamera {
            Settings.selectedCamera = resolvedCamera
        }
        Settings.selectedCameraID = cameraID
        
        let selectedMicrophone = Settings.selectedMicrophone
        var resolvedMicrophone = selectedMicrophone
        var microphoneID = Settings.selectedMicrophoneID.flatMap { savedID in
            AVCaptureDevice(uniqueID: savedID) == nil ? nil : savedID
        }
        if let microphoneID {
            resolvedMicrophone = await deviceActor.getMicrophoneName(microphoneID)
        }
        if microphoneID == nil, let selectedMicrophone {
            microphoneID = await deviceActor.getMicrophoneID(selectedMicrophone)
        }
        if microphoneID == nil, let selectedMicrophone {
            LOG("Cannot find designated microphone \(selectedMicrophone), using preferred microphone", level: .warning)
        }
        if microphoneID == nil {
            microphoneID = await deviceActor.getPreferredMicrophoneID()
            resolvedMicrophone = await deviceActor.getPreferredMicrophoneName()
        }
        if microphoneID == nil {
            LOG("Cannot find preferred microphone, using first available microphone", level: .warning)
            microphoneID = await deviceActor.getFirstMicrophoneID()
            resolvedMicrophone = await deviceActor.getFirstMicrophoneName()
        }
        if resolvedMicrophone == nil, let microphoneID {
            resolvedMicrophone = await deviceActor.getMicrophoneName(microphoneID)
        }
        let microphoneDevice = microphoneID.flatMap { AVCaptureDevice(uniqueID: $0) }
        guard let microphoneDevice else {
            throw CaptureSetupError.noMicrophone
        }
        if Settings.selectedMicrophone != resolvedMicrophone {
            Settings.selectedMicrophone = resolvedMicrophone
        }
        Settings.selectedMicrophoneID = microphoneID
        
        try await deviceActor.setup(
            cameraDevice: cameraDevice,
            microphoneDevice: microphoneDevice,
            session: CaptureDirector.session
        )
        await deviceActor.addCameraControls(session: CaptureDirector.session)
        await deviceActor.findSupportedStabilizationModes()
        let selectedStabilization = Settings.cameraStabilization ?? "Off"
        await setCameraStabilization(to: selectedStabilization)
    }
    func startSessions() async throws {
        try await sessionController.startSessions()
        await eventMonitor.startMonitoring(session: CaptureDirector.session)
    }
    func stopSessions() async {
        await sessionController.stopSessions()
    }
    func cycleSessions() async throws {
        try await sessionController.cycleSessions()
    }
    func startOutput() async throws {
        guard await CaptureDirector.session.isRunning else {
            throw CaptureSetupError.sessionDidNotStart
        }
        do {
            try await deviceActor.startAudioOutput() // start audio first, to ensure we get audio samples with the video
            try await deviceActor.startVideoOutput()
            await deviceActor.setOutputting(true)
        } catch {
            await deviceActor.stopVideoOutput()
            await deviceActor.stopAudioOutput()
            await deviceActor.setOutputting(false)
            throw error
        }
    }
    func stopOutput() async {
        _ = await beginOutputFinalization()
        await finishOutputFinalization()
    }
    /// Freezes the audio tail at the user's Stop action while leaving the
    /// delayed, stabilized video callback attached long enough to catch up.
    func beginOutputFinalization() async -> CMTime? {
        let stopTimestamp = await CaptureDirector.session.synchronizationClock?.time
        await deviceActor.setOutputting(false)
        await deviceActor.stopAudioOutput()
        return stopTimestamp
    }
    func finishOutputFinalization() async {
        await deviceActor.stopVideoOutput()
    }
    func isOutputting() async -> Bool {
        await deviceActor.getOutputting()
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
    func frameRateLookup() async -> [Resolution: Double] {
        await deviceActor.frameRateLookup(for: Settings.selectedCamera)
    }
}

private final class CaptureEventMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []

    func startMonitoring(session: AVCaptureSession) {
        let shouldStart = lock.withLock { observers.isEmpty }
        guard shouldStart else { return }

        let center = NotificationCenter.default
        var newObservers: [NSObjectProtocol] = []
        newObservers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { notification in
            let nsError = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let message: String
            if nsError?.domain == AVFoundationErrorDomain,
               nsError?.code == AVError.mediaServicesWereReset.rawValue {
                message = "Camera media services were reset"
            } else {
                message = nsError?.localizedDescription ?? "The camera session failed"
            }
            let mediaServicesWereReset = nsError?.domain == AVFoundationErrorDomain &&
                nsError?.code == AVError.mediaServicesWereReset.rawValue
            Task {
                if mediaServicesWereReset {
                    await Streamer.shared.handleMediaServicesReset()
                } else {
                    await Streamer.shared.handleRuntimeFailure(
                        CaptureSetupError.configuration(message)
                    )
                }
            }
        })
        newObservers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { _ in
            Task {
                await Streamer.shared.handleRuntimeFailure(
                    CaptureSetupError.configuration("The camera session was interrupted")
                )
            }
        })
        newObservers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: nil
        ) { _ in
            LOG("Camera session interruption ended", level: .info)
        })
        newObservers.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let device = notification.object as? AVCaptureDevice else { return }
            let disconnectedID = device.uniqueID
            Task {
                if Settings.selectedCameraID == disconnectedID ||
                    Settings.selectedMicrophoneID == disconnectedID {
                    await Streamer.shared.handleRuntimeFailure(
                        CaptureSetupError.configuration("The selected capture device was disconnected")
                    )
                }
            }
        })
        newObservers.append(center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: nil
        ) { _ in
            LOG("A capture device was connected; the device list will refresh when opened", level: .info)
        })

        lock.withLock {
            if observers.isEmpty {
                observers = newObservers
            } else {
                newObservers.forEach { center.removeObserver($0) }
            }
        }
    }

    deinit {
        let center = NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
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
        LOG("Searching for best capture format with resolution \(width)x\(height) and \(frameRate) FPS.", level: .debug)
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
                LOG("Found \(candidates.count) pixel format candidates", level: .debug)
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
