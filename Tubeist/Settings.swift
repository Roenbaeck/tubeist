//
//  Settings.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-04.
//
import SwiftUI
import AVFoundation
import PhotosUI

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

    func updateOverlay(id: String, url: String) {
        guard let index = overlays.firstIndex(where: { $0.id == id }) else {
            return
        }

        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.isEmpty {
            return
        }

        if overlays.contains(where: { $0.id != id && $0.url == trimmedURL }) {
            return
        }

        overlays[index].url = trimmedURL
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
    @AppStorage("JournalError") private var journalError: Bool = true
    @AppStorage("JournalWarning") private var journalWarning: Bool = true
    @AppStorage("JournalInfo") private var journalInfo: Bool = true
    @AppStorage("JournalDebug") private var journalDebug: Bool = false
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
    @State private var youtubeService = YouTubeService()
    @State private var broadcastTitle: String = ""
    @State private var broadcastVisibility: String = "public"
    @State private var playlists: [YouTubePlaylist] = []
    @State private var selectedPlaylistId: String? = Settings.youtubeSelectedPlaylistId
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var thumbnailImage: UIImage? = nil
    @State private var broadcastId: String? = nil
    @State private var broadcastScheduledStartTime: String? = nil
    @State private var broadcastLifeCycleStatus: String? = nil
    @State private var youtubeConfigLoaded: Bool = false
    @State private var isYouTubeRefreshCoolingDown: Bool = false
    @State private var editingOverlay: OverlaySetting? = nil
    @State private var editedOverlayURL: String = ""
        
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

                if stream && target == "youtube" && !streamKeyManager.currentKey.isEmpty {
                    Section(header: Text("YouTube Stream Configuration"), footer: Text(youtubeService.isSignedIn ? "Configure the YouTube broadcast tied to your stream key. Changes here are sent to YouTube when you tap Save." : "Sign in with your Google account to configure YouTube broadcast settings for the current stream key.")) {
                        if !youtubeService.isSignedIn {
                            Button("Sign in with Google") {
                                Task {
                                    await youtubeService.signIn()
                                    if youtubeService.isSignedIn {
                                        await loadYouTubeBroadcast()
                                    }
                                }
                            }
                        } else {
                            if youtubeService.isLoading {
                                HStack {
                                    ProgressView()
                                    Text("Loading...")
                                        .foregroundColor(.secondary)
                                }
                            } else if broadcastId != nil {
                                HStack {
                                    Text("Status")
                                    Spacer()
                                    Button {
                                        Task {
                                            await refreshYouTubeBroadcast()
                                        }
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                            .foregroundColor(.secondary)
                                    }
                                    .disabled(youtubeService.isLoading || isYouTubeRefreshCoolingDown)
                                    Circle()
                                        .fill(broadcastLifeCycleStatus == "live" ? Color.red :
                                              broadcastLifeCycleStatus == "testing" ? Color.orange :
                                              broadcastLifeCycleStatus == "ready" ? Color.green : Color.gray)
                                        .frame(width: 10, height: 10)
                                    Text(YouTubeBroadcast.label(for: broadcastLifeCycleStatus))
                                        .foregroundColor(.secondary)
                                }

                                if broadcastLifeCycleStatus == "live" || broadcastLifeCycleStatus == "testing" {
                                    Button("Stop YouTube Stream", role: .destructive) {
                                        Task {
                                            guard let broadcastId else { return }
                                            do {
                                                try await youtubeService.stopBroadcast(id: broadcastId)
                                                await loadYouTubeBroadcast()
                                            } catch {
                                                youtubeService.errorMessage = error.localizedDescription
                                                LOG("Failed to stop broadcast: \(error.localizedDescription)", level: .error)
                                            }
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                }

                                TextField("Stream Title", text: $broadcastTitle)
                                    .autocapitalization(.sentences)

                                Picker("Visibility", selection: $broadcastVisibility) {
                                    Text("Public").tag("public")
                                    Text("Unlisted").tag("unlisted")
                                    Text("Private").tag("private")
                                }

                                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                    HStack {
                                        Text("Thumbnail")
                                        Spacer()
                                        if let thumbnailImage {
                                            Image(uiImage: thumbnailImage)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 64, height: 36)
                                                .clipped()
                                                .cornerRadius(4)
                                        } else {
                                            Text("Select image")
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .onChange(of: selectedPhotoItem) { _, newItem in
                                    Task { @MainActor in
                                        if let data = try? await newItem?.loadTransferable(type: Data.self),
                                           let image = UIImage(data: data) {
                                            thumbnailImage = image
                                        }
                                    }
                                }

                                Picker("Playlist", selection: $selectedPlaylistId) {
                                    Text("None").tag(String?.none)
                                    ForEach(playlists) { playlist in
                                        Text(playlist.title).tag(Optional(playlist.id))
                                    }
                                }
                                .onChange(of: selectedPlaylistId) { _, newValue in
                                    Settings.youtubeSelectedPlaylistId = newValue
                                }

                            } else if let errorMessage = youtubeService.errorMessage {
                                Text(errorMessage)
                                    .foregroundColor(.red)
                                Button("Retry") {
                                    Task {
                                        await loadYouTubeBroadcast()
                                    }
                                }
                            } else if youtubeConfigLoaded {
                                Text("No broadcast found for the current stream key. Make sure you have a scheduled or active broadcast on YouTube.")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                Button("Retry") {
                                    Task {
                                        await loadYouTubeBroadcast()
                                    }
                                }
                            }

                            Button("Sign out of YouTube", role: .destructive) {
                                youtubeService.signOut()
                                broadcastId = nil
                                broadcastTitle = ""
                                playlists = []
                                selectedPlaylistId = nil
                                thumbnailImage = nil
                                youtubeConfigLoaded = false
                                Settings.youtubeSelectedPlaylistId = nil
                                appState.youtubeStatus = nil
                                appState.youtubeBroadcastId = nil
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .onAppear {
                        if youtubeService.isSignedIn && !youtubeConfigLoaded {
                            Task {
                                await loadYouTubeBroadcast()
                            }
                        }
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
                        Button {
                            editingOverlay = overlay
                            editedOverlayURL = overlay.url
                        } label: {
                            HStack {
                                Text(overlay.url)
                                    .foregroundColor(.primary)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: "pencil")
                                    .foregroundColor(.secondary)
                            }
                        }
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
                
                Section(header: Text("Journal"), footer: Text("Configure which types of messages to record in the journal")) {
                    HStack {
                        Toggle("Test", isOn: $journalError).labelsHidden()
                        Text("Error").font(.caption).multilineTextAlignment(.center)
                        Spacer()
                        Toggle("Test", isOn: $journalWarning).labelsHidden()
                        Text("Warning").font(.caption).multilineTextAlignment(.center)
                        Spacer()
                        Toggle("Test", isOn: $journalInfo).labelsHidden()
                        Text("Info").font(.caption).multilineTextAlignment(.center)
                        Spacer()
                        Toggle("Test", isOn: $journalDebug).labelsHidden()
                        Text("Debug").font(.caption).multilineTextAlignment(.center)
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
            .navigationBarItems(leading: Button("Close") {
                presentationMode.wrappedValue.dismiss()
            }, trailing: Button("Save") {
                Settings.configureJournal()
                if cameraPosition == "custom" {
                    LOG("Saving custom settings", level: .debug)
                    saveCustomPreset()
                }
                Task {
                    await Streamer.shared.cycleSessions()
                    if broadcastId != nil && youtubeService.isSignedIn {
                        await applyYouTubeChanges()
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
            .sheet(item: $editingOverlay) { overlay in
                NavigationView {
                    Form {
                        Section(footer: Text("Update the existing overlay URL. Swipe left on the overlay row to delete it instead.")) {
                            TextField("Overlay URL", text: $editedOverlayURL)
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                    }
                    .navigationTitle("Edit Overlay")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarItems(
                        leading: Button("Cancel") {
                            editingOverlay = nil
                        },
                        trailing: Button("Save") {
                            saveOverlayEdit(for: overlay)
                        }
                    )
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

    func saveOverlayEdit(for overlay: OverlaySetting) {
        let trimmedURL = editedOverlayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), UIApplication.shared.canOpenURL(url) else {
            return
        }

        overlayManager.updateOverlay(id: overlay.id, url: trimmedURL)
        editingOverlay = nil
        editedOverlayURL = ""
    }

    func refreshYouTubeBroadcast() async {
        guard !youtubeService.isLoading, !isYouTubeRefreshCoolingDown else {
            return
        }

        isYouTubeRefreshCoolingDown = true
        defer {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                isYouTubeRefreshCoolingDown = false
            }
        }

        await loadYouTubeBroadcast()
    }

    func loadYouTubeBroadcast() async {
        do {
            let broadcast = try await youtubeService.findBroadcastForStreamKey(streamKeyManager.currentKey)
            broadcastId = broadcast.id
            broadcastTitle = broadcast.title
            broadcastVisibility = broadcast.privacyStatus
            broadcastScheduledStartTime = broadcast.scheduledStartTime
            broadcastLifeCycleStatus = broadcast.lifeCycleStatus
            appState.youtubeBroadcastId = broadcast.id
            appState.youtubeStatus = broadcast.lifeCycleStatus
            playlists = try await youtubeService.listPlaylists()
            if let selectedPlaylistId, !playlists.contains(where: { $0.id == selectedPlaylistId }) {
                self.selectedPlaylistId = nil
                Settings.youtubeSelectedPlaylistId = nil
            }
            youtubeConfigLoaded = true
            youtubeService.errorMessage = nil
            LOG("Loaded YouTube broadcast: \(broadcast.title)", level: .info)
        } catch {
            youtubeService.errorMessage = error.localizedDescription
            youtubeConfigLoaded = true
            LOG("Failed to load YouTube broadcast: \(error.localizedDescription)", level: .error)
        }
    }

    func applyYouTubeChanges() async {
        guard let broadcastId else { return }

        do {
            try await youtubeService.updateBroadcast(
                id: broadcastId,
                title: broadcastTitle,
                privacyStatus: broadcastVisibility,
                scheduledStartTime: broadcastScheduledStartTime
            )
        } catch {
            youtubeService.errorMessage = error.localizedDescription
            LOG("Failed to update broadcast: \(error.localizedDescription)", level: .error)
        }

        if let thumbnailImage,
           let resized = thumbnailImage.scaledToFit(maxWidth: 1280, maxHeight: 720),
           let imageData = resized.jpegDataWithinLimit(maxBytes: 2_000_000) {
            do {
                LOG("Uploading thumbnail (\(imageData.count) bytes, \(Int(resized.size.width))x\(Int(resized.size.height)))", level: .debug)
                try await youtubeService.uploadThumbnail(videoId: broadcastId, imageData: imageData)
            } catch {
                youtubeService.errorMessage = error.localizedDescription
                LOG("Failed to upload thumbnail: \(error.localizedDescription)", level: .error)
            }
        }

        if let playlistId = selectedPlaylistId {
            do {
                LOG("Adding broadcast to playlist \(playlistId)", level: .debug)
                try await youtubeService.addToPlaylist(playlistId: playlistId, videoId: broadcastId)
                Settings.youtubeSelectedPlaylistId = playlistId
            } catch {
                youtubeService.errorMessage = error.localizedDescription
                LOG("Failed to add to playlist: \(error.localizedDescription)", level: .error)
            }
        }

        if youtubeService.errorMessage == nil {
            LOG("YouTube broadcast settings applied successfully", level: .info)
        }
    }

}

final class Settings: Sendable {
    private static func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }

    static func configureJournal() {
        let defs = UserDefaults.standard
        let journalError = defs.object(forKey: "JournalError") != nil ? defs.bool(forKey: "JournalError") : true
        let journalWarning = defs.object(forKey: "JournalWarning") != nil ? defs.bool(forKey: "JournalWarning") : true
        let journalInfo = defs.object(forKey: "JournalInfo") != nil ? defs.bool(forKey: "JournalInfo") : true
        let journalDebug = defs.object(forKey: "JournalDebug") != nil ? defs.bool(forKey: "JournalDebug") : false
        Task {
            await journalError ? Journal.shared.enable(level: .error) : Journal.shared.disable(level: .error)
            await journalWarning ? Journal.shared.enable(level: .warning) : Journal.shared.disable(level: .warning)
            await journalInfo ? Journal.shared.enable(level: .info) : Journal.shared.disable(level: .info)
            await journalDebug ? Journal.shared.enable(level: .debug) : Journal.shared.disable(level: .debug)
        }
    }
    
    static func hasCameraPermission() -> Bool {
        let cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch cameraAuthorizationStatus {
        case .authorized:
            return true // Permission granted
        case .denied:
            LOG("User has explicitly denied camera access", level: .warning)
            return false // Permission explicitly denied
        case .restricted:
            LOG("This phone is restricted from using the camera", level: .error)
            return false // Restricted by Mobile Device Management (corporate)
        case .notDetermined:
            // Permission not yet requested (app first launch, or reset)
            LOG("Camera permissions have never been set", level: .debug)
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
        case .denied:
            LOG("User has explicitly denied microphone access", level: .warning)
            return false // Permission explicitly denied or restricted
        case .restricted:
            LOG("This phone is restricted from using the microphone", level: .error)
            return false // Restricted by Mobile Device Management (corporate)
        case .notDetermined:
            // Permission not yet requested
            LOG("Microphone permissions have never been set", level: .debug)
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
            bool(forKey: "InputSyncsWithOutput", default: true)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "InputSyncsWithOutput")
        }
    }
    static var stream: Bool {
        get {
            bool(forKey: "Stream", default: true)
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
    static var areSystemMetricsAtTop: Bool {
        get {
            bool(forKey: "SystemMetricsAtTop", default: false)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "SystemMetricsAtTop")
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
    static var youtubeAccessToken: String? {
        get {
            UserDefaults.standard.string(forKey: "YouTubeAccessToken")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "YouTubeAccessToken")
        }
    }
    static var youtubeRefreshToken: String? {
        get {
            UserDefaults.standard.string(forKey: "YouTubeRefreshToken")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "YouTubeRefreshToken")
        }
    }
    static var youtubeTokenExpiry: Date? {
        get {
            UserDefaults.standard.object(forKey: "YouTubeTokenExpiry") as? Date
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "YouTubeTokenExpiry")
        }
    }
    static var youtubeSelectedPlaylistId: String? {
        get {
            UserDefaults.standard.string(forKey: "YouTubeSelectedPlaylistId")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "YouTubeSelectedPlaylistId")
        }
    }
}
