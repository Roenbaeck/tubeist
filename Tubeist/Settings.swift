//
//  Settings.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-04.
//
import SwiftUI

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
}

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

class OverlaySettingsManager {
    var overlays: [OverlaySetting]

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

struct SettingsView: View {
    var overlayManager: OverlaySettingsManager
    @Environment(AppState.self) var appState
    @Environment(\.presentationMode) private var presentationMode
    @AppStorage("HLSServer") private var hlsServer: String = ""
    @AppStorage("Username") private var hlsUsername: String = ""
    @AppStorage("Password") private var hlsPassword: String = ""
    @AppStorage("Target") private var target: String = DEFAULT_TARGET
    @AppStorage("SaveFragmentsLocally") private var saveFragmentsLocally: Bool = false
    @AppStorage("InputSyncsWithOutput") private var inputSyncsWithOutput: Bool = false
    @AppStorage("MeasuredBandwidth") private var measuredBandwidth: Int = 1000 // in kbit/s
    @AppStorage("NetworkSharing") private var networkSharing: String = "many"
    @AppStorage("CameraPosition") private var cameraPosition: String = "stationary"
    @AppStorage("SelectedPreset") private var selectedPresetData: Data = Data()
    @AppStorage("Overlays") private var overlaysData: Data = Data()
    @State private var newOverlayURL: String = ""
    @State private var selectedPreset: Preset? = nil
    @State private var activeMonitor: Monitor = DEFAULT_MONITOR
    @State private var streamKeyManager = StreamKeyManager()

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
                
                Section(header: Text("Target Platform"), footer: Text("Select the target platform and provide its related stream details.")) {
                    Picker("Target Platform", selection: $target) {
                        Text("YouTube").tag("youtube")
                        Text("Twitch").tag("twitch")
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
                    .onAppear {
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

                Section(header: Text("Active Monitor"), footer: Text("Viewing the captured frames will start half of the rendering pipeline and introduce a lag between what is displayed and what is happning in reality. Use this if you want to confirm that the processed video frames look as expected.")) {
                    Picker("Select the active monitor", selection: $activeMonitor) {
                        Text("Camera preview layer").tag(Monitor.camera)
                        Text("Captured frames with imprinted overlays").tag(Monitor.output)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: activeMonitor) { oldValue, newValue in
                        appState.activeMonitor = newValue
                    }
                }
                       
#if DEBUG
                // Intended for internal use and testing
                Section(header: Text("Internal testing features"), footer: Text("These settings are not part of the final app and only appear in debug mode.")) {
                    Toggle("Save Fragments Locally", isOn: $saveFragmentsLocally)
                }
#endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Save") {
                if cameraPosition == "custom" {
                    LOG("Saving custom settings", level: .debug)
                    saveCustomPreset()
                }
                Task {
                    await Streamer.shared.cycleCamera()
                    await Streamer.shared.setMonitor(activeMonitor)
                    OverlayBundler.shared.refreshCombinedImage()
                }
                presentationMode.wrappedValue.dismiss()
            }
            .buttonStyle(.borderedProminent))
            .onAppear {
                activeMonitor = appState.activeMonitor
                if let preset = try? JSONDecoder().decode(Preset.self, from: selectedPresetData) {
                    selectedPreset = preset
                } else {
                    selectedPreset = nil
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
    static var selectedPreset: Preset? {
        var selectedPreset: Preset?
        if let selectedPresetData = UserDefaults.standard.data(forKey: "SelectedPreset") {
            if let preset = try? JSONDecoder().decode(Preset.self, from: selectedPresetData) {
                selectedPreset = preset
            }
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
    static var saveFragmentsLocally: Bool {
        get {
            UserDefaults.standard.bool(forKey: "SaveFragmentsLocally")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "SaveFragmentsLocally")
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
}
