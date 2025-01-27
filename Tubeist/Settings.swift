//
//  Settings.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-04.
//
import SwiftUI
import AVFoundation

struct Preset: Codable, Equatable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let width: Int
    let height: Int
    let frameRate: Double
    let keyframeInterval: Double
    let audioChannels: Int
    let audioBitrate: Int
    let videoBitrate: Int

    enum CodingKeys: String, CodingKey {
        case name
        case width
        case height
        case frameRate = "frame_rate"
        case keyframeInterval = "keyframe_interval"
        case audioChannels = "audio_channels"
        case audioBitrate = "audio_bitrate"
        case videoBitrate = "video_bitrate"
    }
    
    var description: String {
        return """
        Preset:
        - Name: \(name)
        - Resolution: \(width)x\(height)
        - Frame rate: \(frameRate) FPS
        - Keyframe interval: \(keyframeInterval)s
        - Video bitrate: \(videoBitrate)
        - Audio channels: \(audioChannels)
        - Audio bitrate: \(audioBitrate)        
        """
    }
}

let defaultPreset: Preset = Preset(
    name: "Default",
    width: DEFAULT_COMPRESSED_WIDTH,
    height: DEFAULT_COMPRESSED_HEIGHT,
    frameRate: DEFAULT_FRAMERATE,
    keyframeInterval: DEFAULT_KEYFRAME_INTERVAL,
    audioChannels: DEFAULT_AUDIO_CHANNELS,
    audioBitrate: DEFAULT_AUDIO_BITRATE,
    videoBitrate: DEFAULT_VIDEO_BITRATE
)

let movingCameraPresets: [Preset] = [
    Preset(name: "540p",  width: 960,  height: 540,  frameRate: 30, keyframeInterval: 1.0, audioChannels: 1, audioBitrate: 48_000,  videoBitrate: 1_450_000),
    Preset(name: "720p",  width: 1280, height: 720,  frameRate: 30, keyframeInterval: 1.0, audioChannels: 1, audioBitrate: 64_000,  videoBitrate: 2_900_000),
    Preset(name: "1080p", width: 1920, height: 1080, frameRate: 30, keyframeInterval: 1.0, audioChannels: 2, audioBitrate: 96_000,  videoBitrate: 5_800_000),
    Preset(name: "1440p", width: 2560, height: 1440, frameRate: 30, keyframeInterval: 1.0, audioChannels: 2, audioBitrate: 128_000, videoBitrate: 9_700_000),
    Preset(name: "4K",    width: 3840, height: 2160, frameRate: 30, keyframeInterval: 1.0, audioChannels: 2, audioBitrate: 128_000, videoBitrate: 15_700_000)
]

let stationaryCameraPresets: [Preset] = [
    Preset(name: "540p",  width: 960,  height: 540,  frameRate: 30, keyframeInterval: 2.0, audioChannels: 1, audioBitrate: 48_000,  videoBitrate: 950_000),
    Preset(name: "720p",  width: 1280, height: 720,  frameRate: 30, keyframeInterval: 2.0, audioChannels: 1, audioBitrate: 64_000,  videoBitrate: 1_900_000),
    Preset(name: "1080p", width: 1920, height: 1080, frameRate: 30, keyframeInterval: 2.0, audioChannels: 2, audioBitrate: 96_000,  videoBitrate: 3_900_000),
    Preset(name: "1440p", width: 2560, height: 1440, frameRate: 30, keyframeInterval: 2.0, audioChannels: 2, audioBitrate: 128_000, videoBitrate: 6_700_000),
    Preset(name: "4K",    width: 3840, height: 2160, frameRate: 30, keyframeInterval: 2.0, audioChannels: 2, audioBitrate: 128_000, videoBitrate: 9_700_000)
]

struct Resolution: Hashable {
    let width: Int
    let height: Int
    init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }
}

struct OverlaySetting: Identifiable, Codable, Hashable {
    var id: String { url }
    var url: String

    init(url: String) {
        self.url = url
    }
}

@Observable
class OverlaySettingsManager {
    var overlays: [OverlaySetting] = []

    init() {
        overlays = OverlaySettingsManager.loadOverlaysFromStorage()
    }

    static func loadOverlaysFromStorage() -> [OverlaySetting] {
        guard let overlaysData = Settings.overlaysData,
              let decodedOverlays = try? JSONDecoder().decode([OverlaySetting].self, from: overlaysData) else {
            return []
        }
        return decodedOverlays
    }

    func saveOverlays() {
        guard let encodedOverlays = try? JSONEncoder().encode(overlays) else {
            return
        }
        Settings.overlaysData = encodedOverlays
    }

    func addOverlay(url: String) {
        if !overlays.contains(where: { $0.url == url }) {
            let newOverlay = OverlaySetting(url: url)
            overlays.append(newOverlay)
            saveOverlays()
        }
    }

    func deleteOverlay(at offsets: IndexSet) {
        overlays.remove(atOffsets: offsets)
        saveOverlays()
    }
}

@Observable
class StreamKeyManager {
    var currentKey: String = ""
    
    init() {
        loadKey(for: Settings.target)
    }
    
    private var storage: [String: String] {
        get {
            guard let targetData = Settings.targetData,
                  let decodedTargetData = try? JSONDecoder().decode([String: String].self, from: targetData) else {
                return [:]
            }
            return decodedTargetData
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                Settings.targetData  = encoded
            }
        }
    }
    
    func loadKey(for target: String) {
        currentKey = storage[target] ?? ""
    }
    
    func saveKey(_ key: String, for target: String) {
        var newStorage = storage
        newStorage[target] = key
        storage = newStorage
        currentKey = key
    }
}

enum RecordingOption: String, CaseIterable, Identifiable {
    case streamOnly
    case streamAndRecord
    case recordOnly

    var id: Self { self }

    var description: String {
        switch self {
        case .streamOnly: return "Stream only"
        case .streamAndRecord: return "Stream and Record"
        case .recordOnly: return "Record only"
        }
    }
}

struct SettingsView: View {
    var overlayManager: OverlaySettingsManager
    @Environment(AppState.self) var appState
    @Environment(\.presentationMode) private var presentationMode
    @AppStorage("HLSServer") private var hlsServer: String = ""
    @AppStorage("Username") private var hlsUsername: String = ""
    @AppStorage("Password") private var hlsPassword: String = ""
    @AppStorage("Target") private var target: String = DEFAULT_TARGET
    @AppStorage("Stream") private var stream: Bool = true
    @AppStorage("Record") private var record: Bool = false
    @AppStorage("InputSyncsWithOutput") private var inputSyncsWithOutput: Bool = true // assume energy efficiency is top priority
    @AppStorage("MeasuredBandwidth") private var measuredBandwidth: Int = 1_000 // in kbit/s
    @AppStorage("NetworkSharing") private var networkSharing: String = "many"
    @AppStorage("CameraPosition") private var cameraPosition: String = "stationary"
    @AppStorage("SelectedPreset") private var selectedPresetData: Data = Data()
    @AppStorage("Overlays") private var overlaysData: Data = Data()
    @State private var newOverlayURL: String = ""
    @State private var selectedPreset: Preset? = nil
    @State private var streamKeyManager = StreamKeyManager()
    @State private var selectedOption: RecordingOption = .streamOnly

    // State variables for custom preset settings
    @State private var customResolution: Resolution = Resolution(DEFAULT_COMPRESSED_WIDTH, DEFAULT_COMPRESSED_HEIGHT)
    @State private var customFrameRate: Double = DEFAULT_FRAMERATE
    @State private var customKeyframeInterval: Double = DEFAULT_KEYFRAME_INTERVAL
    @State private var customAudioChannels: Int = DEFAULT_AUDIO_CHANNELS
    @State private var customAudioBitrate: Int = DEFAULT_AUDIO_BITRATE
    @State private var customVideoBitrate: Int = DEFAULT_VIDEO_BITRATE
    @State private var maxFrameRate: Double = DEFAULT_FRAMERATE
        
    var body: some View {
        NavigationView {
            Form {
                if !Settings.hasCameraPermission() || !Settings.hasMicrophonePermission() {
                    Button("Click here and grant Camera and Microphone access in the settings to use the app") {
                        Settings.openSystemSettings()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .foregroundColor(Color.red)
                }

                Section(header: Text("HLS Server and Credentials"), footer: Text("Enter the URI of the HLS relay server and corresponding login details. The server can be downloaded from https://github.com/Roenbaeck/hls-relay.")) {
                    TextField("HLS Server URI", text: $hlsServer)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    TextField("Username", text: $hlsUsername)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textContentType(.username)
                    
                    SecureField("Password", text: $hlsPassword)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textContentType(.password)
                }
                
                Section(header: Text("Target Platform with Recording Options"), footer: Text("Select the target platform and provide its related stream details. You can also select to save a copy of the stream locally on the phone, which can later be transferred to your computer.")) {
                    Picker("Stream or Record", selection: $selectedOption) {
                        ForEach(RecordingOption.allCases) { option in
                            Text(option.description).tag(option)
                        }
                    }
                    .onChange(of: selectedOption) { _, newValue in
                        switch newValue {
                        case .streamOnly:
                            stream = true
                            record = false
                        case .streamAndRecord:
                            stream = true
                            record = true
                        case .recordOnly:
                            stream = false
                            record = true
                        }
                    }

                    if stream {
                        Picker("Target Platform", selection: $target) {
                            Text("YouTube (HDR)").tag("youtube")
                            Text("Twitch (beta, no HDR)").tag("twitch")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: target) { _, newValue in
                            LOG("Changing stream target to: \(newValue)", level: .debug)
                            streamKeyManager.loadKey(for: newValue)
                        }

                        TextField("Stream Key", text: Binding(
                            get: { streamKeyManager.currentKey },
                            set: { streamKeyManager.saveKey($0, for: target) }
                        ))
                        .keyboardType(.asciiCapable)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    }
                }
                .onAppear {
                    if stream && record {
                        selectedOption = .streamAndRecord
                    } else if record {
                        selectedOption = .recordOnly
                    } else {
                        selectedOption = .streamOnly
                    }
                }

                Section(header: Text("Camera"), footer: Text("Select if the camera will be moving around with altering scenery or remain stationary aimed at a single scene. If you do not want to get suggested presets and instead configure settings in detail, select 'Custom' here.")) {
                    Picker("Camera Position", selection: $cameraPosition) {
                        Text("Stationary").tag("stationary")
                        Text("Moving").tag("moving")
                        Text("Custom").tag("custom")
                    }
                    .pickerStyle(.segmented)
                }
                
                // Figure out "sane" presets given some additional information, unless the user wants a custom mode
                if cameraPosition != "custom" {
                    Section(header: Text("Bandwidth"), footer: Text("Measured upload bandwidth in kbit/s (click 'Show More Info' on https://fast.com for example).")) {
                        Text("Measured upload bandwidth: \(String(format: "%.1f", Double(measuredBandwidth) / 1_000_000.0)) Mbps")
                            .font(.callout)
                        Slider(value: Binding(
                            get: { Double(measuredBandwidth) },
                            set: { measuredBandwidth = Int($0) }
                        ), in: 1_000_000...50_000_000, step: 500_000)
                        
                        Picker("People sharing the bandwidth", selection: $networkSharing) {
                            Text("Many (cellular or public WiFi)").tag("many")
                            Text("Few (dedicated WiFi or Ethernet dongle)").tag("few")
                        }
                    }
                    
                    // computed properties
                    var availablePresets: [Preset] {
                        cameraPosition == "moving" ? movingCameraPresets : stationaryCameraPresets
                    }
                    var maximumBitrate: Int {
                        let networkFactor = networkSharing == "many" ? 0.5 : 0.8
                        return Int(Double(measuredBandwidth) * networkFactor)
                    }
                    
                    Section(header: Text("PRESET"), footer: Text("Depending on your selections above, some presets may be determined to result in a poor streaming experience. These are colored red, and should not be used unless your network conditions change.")) {
                        Picker(selection: $selectedPreset) {
                            ForEach(availablePresets) { preset in
                                let unstreamable = (preset.videoBitrate + preset.audioChannels * preset.audioBitrate) > maximumBitrate
                                let presetColor: Color = unstreamable ? .red : .primary
                                Text(preset.name)
                                    .foregroundColor(presetColor)
                                    .tag(Optional(preset))
                            }
                        } label: {
                            // this is the way to trick an inline picker not to show an extra option with the label of the picker
                        }
                        .pickerStyle(.inline)
                        .onChange(of: selectedPreset) { oldValue, newValue in
                            if let selectedPreset = newValue {
                                if let encoded = try? JSONEncoder().encode(selectedPreset) {
                                    selectedPresetData = encoded
                                }
                            }
                        }
                    }
                }
                else {
                    // Allow custom settings here for every part of a Preset, except its name, which should be "Custom"
                    Section(header: Text("Custom Settings")) {
                        Picker("Stream resolution", selection: $customResolution) {
                            Text("960x540").tag(Resolution(960, 540))
                            Text("1280x720").tag(Resolution(1280, 720))
                            Text("1920x1080").tag(Resolution(1920, 1080))
                            Text("2560x1440").tag(Resolution(2560, 1440))
                            Text("3840x2160").tag(Resolution(3840, 2160))
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: customResolution) { oldValue, newValue in
                            Task {
                                maxFrameRate = await CaptureDirector.shared.frameRateLookup[customResolution] ?? DEFAULT_FRAMERATE
                                
                                if customFrameRate > maxFrameRate {
                                    customFrameRate = maxFrameRate
                                }
                            }
                        }
                        
                        Picker("Key frame interval", selection: $customKeyframeInterval) {
                            Text("Two key frames per second").tag(0.5)
                            Text("One key frame per second").tag(1.0)
                            Text("One key frame per two seconds").tag(2.0)
                        }
                        .pickerStyle(.segmented)

                        Picker("Audio channels", selection: $customAudioChannels) {
                            Text("Mono audio channel").tag(1)
                            Text("Stereo audio channels").tag(2)
                        }
                        .pickerStyle(.segmented)
                        
                        Text("Frame rate: \(String(format: "%.0f", customFrameRate)) FPS")
                            .font(.callout)
                        Slider(value: Binding(
                            get: { trunc(customFrameRate) },
                            set: { customFrameRate = min(maxFrameRate, $0 + (customFrameRate - trunc(customFrameRate))) }
                        ), in: 2...maxFrameRate, step: 1) {
                            Text("Whole part of frame rate")
                        } minimumValueLabel: {
                            Text("2")
                        } maximumValueLabel: {
                            Text("\(Int(maxFrameRate))")
                        }

                        Text("Audio bitrate per channel: \(customAudioBitrate / 1000) kbps")
                            .font(.callout)
                        Slider(value: Binding(
                            get: { Double(customAudioBitrate) },
                            set: { customAudioBitrate = Int($0) }
                        ), in: 32_000...128_000, step: 8_000)

                        Text("Video bitrate \(String(format: "%.1f", Double(customVideoBitrate) / 1_000_000.0)) Mbps")
                            .font(.callout)
                        Slider(value: Binding(
                            get: { Double(customVideoBitrate) },
                            set: { customVideoBitrate = Int($0) }
                        ), in: 500_000...50_000_000, step: 500_000)
                    }
                }

                Section {
                    Toggle("Input resolution syncs with output resolution", isOn: $inputSyncsWithOutput)
                } footer: {
                    if inputSyncsWithOutput {
                        Text("Input resolution is synchronized with the output resolution. Camera video frames will be produced in the same resolution as the selected output. This yields the least CPU usage at the cost of a slight loss in color fidelity.")
                    }
                    else {
                        Text("Input resolution is always 4K regardless of output resolution. Camera video frames will be downsampled to the output resolution if it is lower than 4K. This yields the best possible color fidelity at the cost of higher CPU usage.")
                    }
                }
                
                Section(header: Text("Overlays"), footer: Text("Add multiple web overlay URLs that will be imprinted onto the video frames. Overlays are updated on content changes and at most once per second. Audio is captured from the last playing overlay if audio from multiple overlays overlap.")) {
                    ForEach(overlayManager.overlays) { overlay in
                        Text(overlay.url)
                    }
                    .onDelete(perform: overlayManager.deleteOverlay)
                    
                    HStack {
                        TextField("New Overlay URL", text: $newOverlayURL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Button(action: addOverlay) {
                            Image(systemName: "plus.circle.fill")
                        }
                    }
                }
                                
                if !Purchaser.shared.isProductPurchased("tubeist_lifetime_styling") {
                    if let product = appState.availableProducts["tubeist_lifetime_styling"] {
                        Section(header: Text("In-App Purchases"), footer: Text("This set of styles and effects is the only unlockable content in this app, made available at the lowest price possible. Once unlocked you have lifetime access to all styles and effects. It is a small contribution going toward continued app development.")) {
                            HStack {
                                Text("Styles and Effects Lifetime Access")
                                Spacer()
                                Button(product.displayPrice) {
                                    Task {
                                        await Purchaser.shared.purchase(product: product)
                                    }
                                }
                            }
                        }
                    }
                }
                
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Save") {
                if cameraPosition == "custom" {
                    LOG("Saving custom settings", level: .debug)
                    saveCustomPreset()
                }
                Task {
                    let outputting = await CaptureDirector.shared.isOutputting()
                    if outputting {
                        await CaptureDirector.shared.stopOutput()
                    }
                    await FrameGrabber.shared.resetTinkerer()
                    await Streamer.shared.cycleCamera()
                    OverlayBundler.shared.refreshCombinedImage()
                    if outputting {
                        await CaptureDirector.shared.startOutput()
                    }
                }
                presentationMode.wrappedValue.dismiss()
            }
            .buttonStyle(.borderedProminent))
            .onAppear {
                if let preset = try? JSONDecoder().decode(Preset.self, from: selectedPresetData) {
                    selectedPreset = preset
                } else {
                    selectedPreset = nil
                }
                if let preset = selectedPreset, preset.name == "Custom" {
                    customResolution = Resolution(preset.width, preset.height)
                    customFrameRate = preset.frameRate
                    customKeyframeInterval = preset.keyframeInterval
                    customAudioChannels = preset.audioChannels
                    customAudioBitrate = preset.audioBitrate
                    customVideoBitrate = preset.videoBitrate
                }
            }
        }
    }
    
    func saveCustomPreset() {
        let customPreset = Preset(
            name: "Custom",
            width: customResolution.width,
            height: customResolution.height,
            frameRate: customFrameRate,
            keyframeInterval: customKeyframeInterval,
            audioChannels: customAudioChannels,
            audioBitrate: customAudioBitrate,
            videoBitrate: customVideoBitrate
        )

        if let encoded = try? JSONEncoder().encode(customPreset) {
            selectedPresetData = encoded
        }
    }
    
    func addOverlay() {
        guard let url = URL(string: newOverlayURL), UIApplication.shared.canOpenURL(url) else {
            // Handle invalid URL error
            return
        }
        overlayManager.addOverlay(url: newOverlayURL)
        newOverlayURL = ""
    }

}

final class Settings: Sendable {
    static func hasCameraPermission() -> Bool {
        let cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch cameraAuthorizationStatus {
        case .authorized:
            return true // Permission granted
        case .denied, .restricted:
            return false // Permission explicitly denied or restricted
        case .notDetermined:
            // Permission not yet requested (app first launch, or reset)
            return false // Treat as denied for settings menu check
        @unknown default:
            return false // Handle future cases (best practice)
        }
    }

    static func hasMicrophonePermission() -> Bool {
        let microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch microphoneAuthorizationStatus {
        case .authorized:
            return true // Permission granted
        case .denied, .restricted:
            return false // Permission explicitly denied or restricted
        case .notDetermined:
            // Permission not yet requested
            return false // Treat as denied for settings menu check
        @unknown default:
            return false // Handle future cases (best practice)
        }
    }

    static func openSystemSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            return // Settings URL is invalid (shouldn't happen but good to check)
        }
        Task { @MainActor in
            if UIApplication.shared.canOpenURL(settingsURL) {
                UIApplication.shared.open(settingsURL, options: [:], completionHandler: nil)
            }
        }
    }
    
    static var selectedPreset: Preset {
        var selectedPreset: Preset?
        if let selectedPresetData = UserDefaults.standard.data(forKey: "SelectedPreset") {
            if let preset = try? JSONDecoder().decode(Preset.self, from: selectedPresetData) {
                selectedPreset = preset
            }
        }
        guard let selectedPreset = selectedPreset, selectedPreset.name != "" else {
            return defaultPreset
        }
        return selectedPreset
    }
    static var streamKey: String? {
        guard let targetData = Settings.targetData,
              let decodedTargetData = try? JSONDecoder().decode([String: String].self, from: targetData),
              let streamKey = decodedTargetData[Settings.target]
        else {
            return nil
        }
        return streamKey
    }
    
    static var isInputSyncedWithOutput: Bool {
        get {
            UserDefaults.standard.bool(forKey: "InputSyncsWithOutput")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "InputSyncsWithOutput")
        }
    }
    static var stream: Bool {
        get {
            UserDefaults.standard.bool(forKey: "Stream")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "Stream")
        }
    }
    static var record: Bool {
        get {
            UserDefaults.standard.bool(forKey: "Record")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "Record")
        }
    }
    static var selectedCamera: String {
        get {
            UserDefaults.standard.string(forKey: "SelectedCamera") ?? DEFAULT_CAMERA
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "SelectedCamera")
        }
    }
    static var hlsServer: String? {
        get {
            UserDefaults.standard.string(forKey: "HLSServer")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "HLSServer")
        }
    }
    static var hlsUsername: String? {
        get {
            UserDefaults.standard.string(forKey: "Username")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "Username")
        }
    }
    static var hlsPassword: String? {
        get {
            UserDefaults.standard.string(forKey: "Password")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "Password")
        }
    }
    static var target: String {
        get {
            UserDefaults.standard.string(forKey: "Target") ?? DEFAULT_TARGET
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "Target")
        }
    }
    static var cameraStabilization: String? {
        get {
            UserDefaults.standard.string(forKey: "CameraStabilization")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "CameraStabilization")
        }
    }
    static var hideOverlays: Bool {
        get {
            UserDefaults.standard.bool(forKey: "HideOverlays")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "HideOverlays")
        }
    }
    static var overlaysData: Data? {
        get {
            UserDefaults.standard.data(forKey: "Overlays")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "Overlays")
        }
    }
    static var targetData: Data? {
        get {
            UserDefaults.standard.data(forKey: "TargetData")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "TargetData")
        }
    }
    static var style: String? {
        get {
            if let style = UserDefaults.standard.string(forKey: "Style"),
               style != NO_STYLE,
               AVAILABLE_STYLES.contains(style) {
                return style
            }
            return nil
        }
        set {
            if newValue == NO_STYLE {
                UserDefaults.standard.set(nil, forKey: "Style")
            }
            else {
                UserDefaults.standard.set(newValue, forKey: "Style")
            }
        }
    }
    static var effect: String? {
        get {
            if let effect = UserDefaults.standard.string(forKey: "Effect"),
               effect != NO_EFFECT,
               AVAILABLE_EFFECTS.contains(effect) {
                return effect
            }
            return nil
        }
        set {
            if newValue == NO_EFFECT {
                UserDefaults.standard.set(nil, forKey: "Effect")
            }
            else {
                UserDefaults.standard.set(newValue, forKey: "Effect")
            }
        }
    }
}
