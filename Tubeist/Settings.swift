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
    let frameRate: Int
    let keyframeInterval: Int
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
    Preset(name: "480p",  width: 640,  height: 480,  frameRate: 30, keyframeInterval: 1, audioChannels: 1, audioBitrate: 48_000, videoBitrate: 1_450_000),
    Preset(name: "720p",  width: 1280, height: 720,  frameRate: 30, keyframeInterval: 1, audioChannels: 1, audioBitrate: 48_000, videoBitrate: 2_950_000),
    Preset(name: "1080p", width: 1920, height: 1080, frameRate: 30, keyframeInterval: 1, audioChannels: 2, audioBitrate: 48_000, videoBitrate: 5_900_000),
    Preset(name: "1440p", width: 2560, height: 1440, frameRate: 30, keyframeInterval: 1, audioChannels: 2, audioBitrate: 64_000, videoBitrate: 9_800_000),
    Preset(name: "4K",    width: 3840, height: 2160, frameRate: 30, keyframeInterval: 1, audioChannels: 2, audioBitrate: 64_000, videoBitrate: 14_800_000)
]

let stationaryCameraPresets: [Preset] = [
    Preset(name: "480p",  width: 640,  height: 480,  frameRate: 30, keyframeInterval: 2, audioChannels: 1, audioBitrate: 48_000, videoBitrate: 950_000),
    Preset(name: "720p",  width: 1280, height: 720,  frameRate: 30, keyframeInterval: 2, audioChannels: 1, audioBitrate: 48_000, videoBitrate: 1_950_000),
    Preset(name: "1080p", width: 1920, height: 1080, frameRate: 30, keyframeInterval: 2, audioChannels: 2, audioBitrate: 48_000, videoBitrate: 3_900_000),
    Preset(name: "1440p", width: 2560, height: 1440, frameRate: 30, keyframeInterval: 2, audioChannels: 2, audioBitrate: 64_000, videoBitrate: 6_800_000),
    Preset(name: "4K",    width: 3840, height: 2160, frameRate: 30, keyframeInterval: 2, audioChannels: 2, audioBitrate: 64_000, videoBitrate: 9_800_000)
]

struct OverlaySetting: Identifiable, Codable, Hashable {
    var id: String { url }
    var url: String

    init(url: String) {
        self.url = url
    }
}

@Observable class OverlaySettingsManager {
    var overlays: [OverlaySetting]

    init() {
        overlays = OverlaySettingsManager.loadOverlaysFromStorage()
    }

    static func loadOverlaysFromStorage() -> [OverlaySetting] {
        guard let overlaysData = UserDefaults.standard.data(forKey: "Overlays"),
              let decodedOverlays = try? JSONDecoder().decode([OverlaySetting].self, from: overlaysData) else {
            return []
        }
        return decodedOverlays
    }

    func saveOverlays() {
        guard let encodedOverlays = try? JSONEncoder().encode(overlays) else {
            return
        }
        UserDefaults.standard.set(encodedOverlays, forKey: "Overlays")
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

struct SettingsView: View {
    var overlayManager: OverlaySettingsManager
    @Environment(\.presentationMode) private var presentationMode
    @AppStorage("HLSServer") private var hlsServer: String = ""
    @AppStorage("StreamKey") private var streamKey: String = ""
    @AppStorage("Username") private var username: String = ""
    @AppStorage("Password") private var password: String = ""
    @AppStorage("SaveFragmentsLocally") private var saveFragmentsLocally: Bool = false
    @AppStorage("MeasuredBandwidth") private var measuredBandwidth: Int = 1000 // in kbit/s
    @AppStorage("NetworkSharing") private var networkSharing: String = "many"
    @AppStorage("CameraPosition") private var cameraPosition: String = "stationary"
    @AppStorage("SelectedPreset") private var selectedPresetData: Data = Data()
    @AppStorage("Overlays") private var overlaysData: Data = Data()
    @State private var newOverlayURL: String = ""
    @State private var selectedPreset: Preset? = nil

    private struct Resolution: Hashable {
        let width: Int
        let height: Int
        init(_ width: Int, _ height: Int) {
            self.width = width
            self.height = height
        }
    }
    
    // State variables for custom preset settings
    @State private var customResolution: Resolution = Resolution(1920, 1080)
    @State private var customFrameRate: Int = 30
    @State private var customKeyframeInterval: Int = 2
    @State private var customAudioChannels: Int = 2
    @State private var customAudioBitrate: Int = 48_000
    @State private var customVideoBitrate: Int = 4_000_000
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("HLS Server"), footer: Text("Enter the URI of the HLS streaming server.")) {
                    TextField("HLS Server URI", text: $hlsServer)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                
                Section(header: Text("Authentication"), footer: Text("Provide your streaming server login details.")) {
                    TextField("Stream Key", text: $streamKey)
                        .keyboardType(.asciiCapable)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
 
                    TextField("Username", text: $username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textContentType(.username)
                    
                    SecureField("Password", text: $password)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textContentType(.password)
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
                        ), in: 1_000_000...15_000_000, step: 500_000)
                        
                        Picker("People sharing the bandwidth", selection: $networkSharing) {
                            Text("Many (cellular or public WiFi)").tag("many")
                            Text("Few (dedicated WiFi or Ethernet dongle)").tag("few")
                        }
                    }
                    
                    let availablePresets = cameraPosition == "moving" ? movingCameraPresets : stationaryCameraPresets
                    var maximumBitrate: Int {
                        let networkFactor = networkSharing == "many" ? 0.5 : 0.8
                        return Int(Double(measuredBandwidth) * networkFactor)
                    }
                    
                    Picker("Stream Preset", selection: $selectedPreset) {
                        ForEach(availablePresets) { preset in
                            let presetColor: Color = preset.videoBitrate + preset.audioBitrate > maximumBitrate ? .red : .primary
                            Text(preset.name)
                                .foregroundColor(presetColor)
                                .tag(Optional(preset))
                        }
                    }
                    .pickerStyle(.inline)
                    .onChange(of: selectedPreset) { oldValue, newValue in
                        if let selectedPreset = newValue {
                            if let encoded = try? JSONEncoder().encode(selectedPreset) {
                                selectedPresetData = encoded
                            }
                        }
                    }
                    
                    Section {
                        EmptyView()
                    } footer: {
                        Text("Depending on your selections above, some presets may be determined to result in a poor streaming experience. These are colored red, and should not be used unless your network conditions change.")
                    }
                    .offset(y: -30)
                }
                else {
                    // Allow custom settings here for every part of a Preset, except its name, which should be "Custom"
                    Section(header: Text("Custom Settings")) {
                        Picker("Stream resolution", selection: $customResolution) {
                            Text("640x480").tag(Resolution(640, 480))
                            Text("1280x720").tag(Resolution(1280, 720))
                            Text("1920x1080").tag(Resolution(1920, 1080))
                            Text("2560x1440").tag(Resolution(2560, 1440))
                            Text("3840x2160").tag(Resolution(3840, 2160))
                        }
                        .pickerStyle(.segmented)
                        
                        Picker("Key frame interval", selection: $customKeyframeInterval) {
                            Text("Every second").tag(1)
                            Text("Every two seconds").tag(2)
                        }
                        .pickerStyle(.segmented)

                        Picker("Audio channels", selection: $customAudioChannels) {
                            Text("Mono").tag(1)
                            Text("Stereo").tag(2)
                        }
                        .pickerStyle(.segmented)

                        Text("Frame rate: \(customFrameRate) FPS")
                            .font(.callout)
                        Slider(value: Binding(
                            get: { Double(customFrameRate) },
                            set: { customFrameRate = Int($0) }
                        ), in: 1...60, step: 1)

                        Text("Audio bitrate per channel: \(customAudioBitrate / 1000) kbps")
                            .font(.callout)
                        Slider(value: Binding(
                            get: { Double(customAudioBitrate) },
                            set: { customAudioBitrate = Int($0) }
                        ), in: 8_000...72_000, step: 8_000)

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
                
                Section(header: Text("Overlays"), footer: Text("Add multiple web overlay URLs for your stream.")) {
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
                
                Section {
                    Toggle("Save Fragments Locally", isOn: $saveFragmentsLocally)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Save") {
                if cameraPosition == "custom" {
                    LOG("Saving custom settings", level: .debug)
                    saveCustomPreset()
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
    static func getSelectedPreset() -> Preset? {
        var selectedPreset: Preset?
        if let selectedPresetData = UserDefaults.standard.data(forKey: "SelectedPreset") {
            if let preset = try? JSONDecoder().decode(Preset.self, from: selectedPresetData) {
                selectedPreset = preset
            }
        }
        return selectedPreset
    }
}
