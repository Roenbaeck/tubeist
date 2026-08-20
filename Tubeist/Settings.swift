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

    func replaceOverlays(with overlays: [OverlaySetting]) {
        self.overlays = overlays
        saveOverlays()
    }
}

@Observable
class StreamKeyManager {
    var currentKey: String
    
    init() {
        currentKey = Settings.streamKey ?? ""
    }
    
    func updateKey(_ key: String) {
        currentKey = key
    }

    func commit() throws {
        try Settings.setStreamKey(currentKey.isEmpty ? nil : currentKey)
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

private struct AppliedSettingsSnapshot {
    let streamKey: String?
    let stream: Bool
    let record: Bool
    let inputSyncsWithOutput: Bool
    let measuredBandwidth: Int
    let networkSharing: String
    let cameraPosition: String
    let selectedPresetData: Data
    let journalError: Bool
    let journalWarning: Bool
    let journalInfo: Bool
    let journalDebug: Bool
    let selectedPlaylistID: String?
    let overlays: [OverlaySetting]
#if DEBUG
    let captureRemuxFixtures: Bool
    let recordHLSAcceptance: Bool
#endif

    static func capture(overlays: [OverlaySetting]) throws -> Self {
#if DEBUG
        Self(
            streamKey: try Settings.loadStreamKey(),
            stream: Settings.stream,
            record: Settings.record,
            inputSyncsWithOutput: Settings.isInputSyncedWithOutput,
            measuredBandwidth: Settings.measuredBandwidth,
            networkSharing: Settings.networkSharing,
            cameraPosition: Settings.cameraPosition,
            selectedPresetData: Settings.selectedPresetData,
            journalError: Settings.journalError,
            journalWarning: Settings.journalWarning,
            journalInfo: Settings.journalInfo,
            journalDebug: Settings.journalDebug,
            selectedPlaylistID: Settings.youtubeSelectedPlaylistId,
            overlays: overlays,
            captureRemuxFixtures: Settings.captureRemuxFixtures,
            recordHLSAcceptance: Settings.recordHLSAcceptance
        )
#else
        Self(
            streamKey: try Settings.loadStreamKey(),
            stream: Settings.stream,
            record: Settings.record,
            inputSyncsWithOutput: Settings.isInputSyncedWithOutput,
            measuredBandwidth: Settings.measuredBandwidth,
            networkSharing: Settings.networkSharing,
            cameraPosition: Settings.cameraPosition,
            selectedPresetData: Settings.selectedPresetData,
            journalError: Settings.journalError,
            journalWarning: Settings.journalWarning,
            journalInfo: Settings.journalInfo,
            journalDebug: Settings.journalDebug,
            selectedPlaylistID: Settings.youtubeSelectedPlaylistId,
            overlays: overlays
        )
#endif
    }

    func restore(overlays manager: OverlaySettingsManager) throws {
        try Settings.setStreamKey(streamKey)
        Settings.stream = stream
        Settings.record = record
        Settings.isInputSyncedWithOutput = inputSyncsWithOutput
        Settings.measuredBandwidth = measuredBandwidth
        Settings.networkSharing = networkSharing
        Settings.cameraPosition = cameraPosition
        Settings.selectedPresetData = selectedPresetData
        Settings.journalError = journalError
        Settings.journalWarning = journalWarning
        Settings.journalInfo = journalInfo
        Settings.journalDebug = journalDebug
        Settings.youtubeSelectedPlaylistId = selectedPlaylistID
        manager.replaceOverlays(with: overlays)
#if DEBUG
        Settings.captureRemuxFixtures = captureRemuxFixtures
        Settings.recordHLSAcceptance = recordHLSAcceptance
#endif
        Settings.configureJournal()
    }
}

struct SettingsView: View {
    var overlayManager: OverlaySettingsManager
    @Environment(AppState.self) var appState
    @Environment(\.presentationMode) private var presentationMode
    @State private var stream: Bool = Settings.stream
    @State private var record: Bool = Settings.record
    @State private var inputSyncsWithOutput: Bool = Settings.isInputSyncedWithOutput
    @State private var measuredBandwidth: Int = Settings.measuredBandwidth
    @State private var networkSharing: String = Settings.networkSharing
    @State private var cameraPosition: String = Settings.cameraPosition
    @State private var selectedPresetData: Data = Settings.selectedPresetData
    @State private var journalError: Bool = Settings.journalError
    @State private var journalWarning: Bool = Settings.journalWarning
    @State private var journalInfo: Bool = Settings.journalInfo
    @State private var journalDebug: Bool = Settings.journalDebug
#if DEBUG
    @State private var captureRemuxFixtures: Bool = Settings.captureRemuxFixtures
    @State private var recordHLSAcceptance: Bool = Settings.recordHLSAcceptance
#endif
    @State private var newOverlayURL: String = ""
    @State private var selectedPreset: Preset? = nil
    @State private var streamKeyManager = StreamKeyManager()
    @State private var selectedOption: RecordingOption = .streamOnly
    @State private var revealsStreamKey = false

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
    @State private var broadcastEnableDvr: Bool = true
    @State private var broadcastLatencyPreference: String = "normal"
    @State private var loadedBroadcast: YouTubeBroadcast? = nil
    @State private var youtubeConfigLoaded: Bool = false
    @State private var isYouTubeRefreshCoolingDown: Bool = false
    @State private var editingOverlay: OverlaySetting? = nil
    @State private var editedOverlayURL: String = ""
    @State private var overlayDraft: [OverlaySetting] = []
    @State private var isApplying = false
    @State private var applyErrorMessage: String?
        
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

                Section(header: Text("YouTube Streaming and Recording"), footer: Text("Stream directly to YouTube with an HLS stream key, save an original-quality recording on this phone, or do both.")) {
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
                        HStack {
                            if revealsStreamKey {
                                TextField("YouTube HLS Stream Key", text: streamKeyBinding)
                                    .keyboardType(.asciiCapable)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            } else {
                                SecureField("YouTube HLS Stream Key", text: streamKeyBinding)
                                    .keyboardType(.asciiCapable)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            }
                            Button {
                                revealsStreamKey.toggle()
                            } label: {
                                Image(systemName: revealsStreamKey ? "eye.slash" : "eye")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(revealsStreamKey ? "Hide stream key" : "Reveal stream key")
                        }
                    }
                }
                .onAppear {
                    if stream && record {
                        selectedOption = .streamAndRecord
                    } else if record {
                        selectedOption = .recordOnly
                    } else if stream {
                        selectedOption = .streamOnly
                    } else {
                        selectedOption = .recordOnly
                        record = true
                    }
                }

                if stream && !streamKeyManager.currentKey.isEmpty {
                    Section(header: Text("YouTube Stream Configuration"), footer: Text(youtubeService.isSignedIn ? "Configure the YouTube broadcast tied to your stream key. Changes here are sent to YouTube only after Apply succeeds." : "Sign in with your Google account to configure YouTube broadcast settings for the current stream key.")) {
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
                                            .frame(width: 44, height: 44)
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

                                Toggle("DVR (viewers can rewind)", isOn: $broadcastEnableDvr)
                                Picker("Latency", selection: $broadcastLatencyPreference) {
                                    Text("Normal").tag("normal")
                                    Text("Low").tag("low")
                                    Text("Ultra-low").tag("ultraLow")
                                }

                                let previewThumbnail = thumbnailImage
                                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                    HStack {
                                        Text("Thumbnail")
                                        if let previewThumbnail {
                                            Image(uiImage: previewThumbnail)
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
                                clearYouTubeAccountState()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .task(id: streamKeyManager.currentKey) {
                        let streamKey = streamKeyManager.currentKey
                        resetLoadedYouTubeBroadcast()
                        guard youtubeService.isSignedIn else { return }
                        do {
                            try await Task.sleep(for: .milliseconds(400))
                        } catch {
                            return
                        }
                        guard !Task.isCancelled else { return }
                        await loadYouTubeBroadcast(forStreamKey: streamKey)
                    }
                }

#if DEBUG
                Section(
                    header: Text("YouTube HLS Development"),
                    footer: Text("Diagnostics are opt-in and remain off in normal use. Fixture capture saves one bounded sample set; acceptance recording appends bounded event lines for a single session.")
                ) {
                    Toggle("Capture fMP4 remux fixtures", isOn: $captureRemuxFixtures)
                    Toggle("Record YouTube HLS acceptance events", isOn: $recordHLSAcceptance)
                }
#endif

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
                                let frameRates = await CaptureDirector.shared.frameRateLookup()
                                maxFrameRate = frameRates[customResolution] ?? DEFAULT_FRAMERATE
                                
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
                    ForEach(overlayDraft) { overlay in
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
                    .onDelete { offsets in
                        overlayDraft.remove(atOffsets: offsets)
                    }
                    
                    HStack {
                        TextField("New Overlay URL", text: $newOverlayURL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Button(action: addOverlay) {
                            Image(systemName: "plus.circle.fill")
                                .frame(width: 44, height: 44)
                        }
                    }
                }
                
                Section(header: Text("Journal"), footer: Text("Configure which types of messages to record in the journal")) {
                    HStack {
                        Toggle("Error", isOn: $journalError).labelsHidden()
                            .accessibilityLabel("Error journal messages")
                        Text("Error").font(.caption).multilineTextAlignment(.center)
                        Spacer()
                        Toggle("Warning", isOn: $journalWarning).labelsHidden()
                            .accessibilityLabel("Warning journal messages")
                        Text("Warning").font(.caption).multilineTextAlignment(.center)
                        Spacer()
                        Toggle("Info", isOn: $journalInfo).labelsHidden()
                            .accessibilityLabel("Informational journal messages")
                        Text("Info").font(.caption).multilineTextAlignment(.center)
                        Spacer()
                        Toggle("Debug", isOn: $journalDebug).labelsHidden()
                            .accessibilityLabel("Debug journal messages")
                        Text("Debug").font(.caption).multilineTextAlignment(.center)
                    }
                }

                Section(header: Text("Privacy and Credentials"), footer: Text("Tubeist stores the HLS stream key and optional Google authorization in the iOS Keychain. Removing them disables streaming until a new key is entered.")) {
                    Link(
                        "Read the Tubeist Privacy Policy",
                        destination: URL(string: "https://github.com/Roenbaeck/tubeist/blob/main/PRIVACY.md")!
                    )
                    if !streamKeyManager.currentKey.isEmpty || youtubeService.isSignedIn {
                        Button("Remove YouTube Credentials", role: .destructive) {
                            do {
                                try Settings.setStreamKey(nil)
                                streamKeyManager.updateKey("")
                                clearYouTubeAccountState()
                                if let errorMessage = youtubeService.errorMessage {
                                    appState.activeAlert = errorMessage
                                }
                            } catch {
                                appState.activeAlert = "Could not remove the YouTube stream key: \(error.localizedDescription)"
                                LOG("Could not remove the YouTube stream key from Keychain", level: .error)
                            }
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
            .navigationBarItems(leading: Button("Close") {
                presentationMode.wrappedValue.dismiss()
            }.disabled(isApplying), trailing: Button("Apply") {
                Task {
                    isApplying = true
                    defer { isApplying = false }
                    var previousSettings: AppliedSettingsSnapshot?
                    var localSettingsCommitted = false
                    var attemptedYouTubeMutation = false
                    do {
                        try validateDraft()
                        previousSettings = try AppliedSettingsSnapshot.capture(
                            overlays: overlayManager.overlays
                        )
                        if cameraPosition == "custom" {
                            saveCustomPreset()
                        }
                        try commitDraft()
                        localSettingsCommitted = true
                        try await Streamer.shared.cycleSessions()
                        if broadcastId != nil && youtubeService.isSignedIn {
                            attemptedYouTubeMutation = true
                            try await applyYouTubeChanges()
                        }
                        Settings.configureJournal()
                        youtubeService.errorMessage = nil
                        applyErrorMessage = nil
                        presentationMode.wrappedValue.dismiss()
                    } catch {
                        var failureMessage = error.localizedDescription
                        if localSettingsCommitted, let previousSettings {
                            do {
                                try previousSettings.restore(overlays: overlayManager)
                                try await Streamer.shared.cycleSessions()
                                failureMessage += " Local app settings were restored."
                            } catch {
                                failureMessage += " Restoring the previous app settings also failed: \(error.localizedDescription)"
                            }
                        }
                        if attemptedYouTubeMutation {
                            failureMessage += " YouTube may have accepted an earlier part of the request; refresh before trying again."
                        }
                        youtubeService.errorMessage = failureMessage
                        applyErrorMessage = failureMessage
                        LOG("Could not apply settings: \(error.localizedDescription)", level: .error)
                    }
                }
            }
            .disabled(isApplying)
            .buttonStyle(.borderedProminent))
            .onAppear {
                overlayDraft = overlayManager.overlays
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
            .alert(
                "Could Not Apply Settings",
                isPresented: Binding(
                    get: { applyErrorMessage != nil },
                    set: { if !$0 { applyErrorMessage = nil } }
                )
            ) {
                Button("OK") { applyErrorMessage = nil }
            } message: {
                Text(applyErrorMessage ?? "The settings could not be applied")
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

    private var streamKeyBinding: Binding<String> {
        Binding(
            get: { streamKeyManager.currentKey },
            set: { streamKeyManager.updateKey($0) }
        )
    }

    private func clearYouTubeAccountState() {
        guard youtubeService.signOut() else { return }
        broadcastId = nil
        broadcastTitle = ""
        playlists = []
        selectedPlaylistId = nil
        thumbnailImage = nil
        youtubeConfigLoaded = false
        appState.youtubeStatus = nil
        appState.youtubeBroadcastId = nil
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
        let trimmedURL = newOverlayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OverlayURLValidator.isAllowed(trimmedURL),
              !overlayDraft.contains(where: { $0.url == trimmedURL }) else { return }
        overlayDraft.append(OverlaySetting(url: trimmedURL))
        newOverlayURL = ""
    }

    func saveOverlayEdit(for overlay: OverlaySetting) {
        let trimmedURL = editedOverlayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OverlayURLValidator.isAllowed(trimmedURL),
              !overlayDraft.contains(where: { $0.id != overlay.id && $0.url == trimmedURL }),
              let index = overlayDraft.firstIndex(where: { $0.id == overlay.id }) else { return }
        overlayDraft[index].url = trimmedURL
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

    func resetLoadedYouTubeBroadcast() {
        broadcastId = nil
        broadcastTitle = ""
        broadcastVisibility = "public"
        broadcastScheduledStartTime = nil
        broadcastLifeCycleStatus = nil
        broadcastEnableDvr = true
        broadcastLatencyPreference = "normal"
        loadedBroadcast = nil
        playlists = []
        youtubeConfigLoaded = false
        youtubeService.errorMessage = nil
        appState.youtubeBroadcastId = nil
        appState.youtubeStatus = nil
    }

    func loadYouTubeBroadcast(forStreamKey requestedStreamKey: String? = nil) async {
        let streamKey = requestedStreamKey ?? streamKeyManager.currentKey
        guard !streamKey.isEmpty else {
            resetLoadedYouTubeBroadcast()
            return
        }
        resetLoadedYouTubeBroadcast()
        do {
            let broadcast = try await youtubeService.findBroadcastForStreamKey(streamKey)
            let loadedPlaylists = try await youtubeService.listPlaylists()
            guard streamKey == streamKeyManager.currentKey, !Task.isCancelled else {
                return
            }
            broadcastId = broadcast.id
            broadcastTitle = broadcast.title
            broadcastVisibility = broadcast.privacyStatus
            broadcastScheduledStartTime = broadcast.scheduledStartTime
            broadcastLifeCycleStatus = broadcast.lifeCycleStatus
            broadcastEnableDvr = broadcast.enableDvr
            broadcastLatencyPreference = broadcast.latencyPreference
            loadedBroadcast = broadcast
            appState.youtubeBroadcastId = broadcast.id
            appState.youtubeStatus = broadcast.lifeCycleStatus
            playlists = loadedPlaylists
            if let selectedPlaylistId, !playlists.contains(where: { $0.id == selectedPlaylistId }) {
                self.selectedPlaylistId = nil
            }
            youtubeConfigLoaded = true
            youtubeService.errorMessage = nil
            LOG("Loaded YouTube broadcast: \(broadcast.title)", level: .info)
        } catch {
            guard streamKey == streamKeyManager.currentKey, !Task.isCancelled else {
                return
            }
            youtubeService.errorMessage = error.localizedDescription
            youtubeConfigLoaded = true
            LOG("Failed to load YouTube broadcast: \(error.localizedDescription)", level: .error)
        }
    }

    func applyYouTubeChanges() async throws {
        guard let currentBroadcast = loadedBroadcast else { return }
        let current = try await youtubeService.ensureCurrentBroadcastForStreamKey(
            streamKeyManager.currentKey
        )
        let targetBroadcastID = current.id

        try await youtubeService.updateBroadcast(
                id: targetBroadcastID,
                title: broadcastTitle,
                privacyStatus: broadcastVisibility,
                scheduledStartTime: broadcastScheduledStartTime,
                enableDvr: broadcastEnableDvr,
                latencyPreference: broadcastLatencyPreference,
                enableMonitorStream: currentBroadcast.enableMonitorStream,
                broadcastStreamDelayMs: currentBroadcast.broadcastStreamDelayMs,
                enableEmbed: currentBroadcast.enableEmbed,
                recordFromStart: currentBroadcast.recordFromStart,
                enableAutoStart: currentBroadcast.enableAutoStart,
                enableAutoStop: currentBroadcast.enableAutoStop
            )
            var updatedBroadcast = current
            updatedBroadcast.title = broadcastTitle
            updatedBroadcast.privacyStatus = broadcastVisibility
            updatedBroadcast.lifeCycleStatus = broadcastLifeCycleStatus
            updatedBroadcast.enableDvr = broadcastEnableDvr
            updatedBroadcast.latencyPreference = broadcastLatencyPreference
            loadedBroadcast = updatedBroadcast
            broadcastId = targetBroadcastID

        if let thumbnailImage,
           let resized = thumbnailImage.scaledToFit(maxWidth: 1280, maxHeight: 720) {
            guard let imageData = resized.jpegDataWithinLimit(maxBytes: 2_000_000) else {
                throw YouTubeError.thumbnailTooLarge
            }
            LOG("Uploading thumbnail (\(imageData.count) bytes, \(Int(resized.size.width))x\(Int(resized.size.height)))", level: .debug)
            try await youtubeService.uploadThumbnail(videoId: targetBroadcastID, imageData: imageData)
        }

        if let playlistId = selectedPlaylistId {
            LOG("Adding broadcast to playlist \(playlistId)", level: .debug)
            try await youtubeService.addToPlaylist(playlistId: playlistId, videoId: targetBroadcastID)
        }
        Settings.youtubeSelectedPlaylistId = selectedPlaylistId
        LOG("YouTube broadcast settings applied successfully", level: .info)
    }

    private func validateDraft() throws {
        guard stream || record else {
            throw SettingsApplyError.noOutputSelected
        }
        if stream {
            guard !streamKeyManager.currentKey.isEmpty else {
                throw StreamStartError.missingStreamKey
            }
            _ = try YouTubeHLSEndpoint.manualPrimary(streamKey: streamKeyManager.currentKey)
        }
        guard measuredBandwidth >= 1_000_000 else {
            throw SettingsApplyError.invalidBandwidth
        }
    }

    private func commitDraft() throws {
        try streamKeyManager.commit()
        Settings.stream = stream
        Settings.record = record
        Settings.isInputSyncedWithOutput = inputSyncsWithOutput
        Settings.measuredBandwidth = measuredBandwidth
        Settings.networkSharing = networkSharing
        Settings.cameraPosition = cameraPosition
        Settings.selectedPresetData = selectedPresetData
        Settings.journalError = journalError
        Settings.journalWarning = journalWarning
        Settings.journalInfo = journalInfo
        Settings.journalDebug = journalDebug
        Settings.youtubeSelectedPlaylistId = selectedPlaylistId
        overlayManager.replaceOverlays(with: overlayDraft)
#if DEBUG
        Settings.captureRemuxFixtures = captureRemuxFixtures
        Settings.recordHLSAcceptance = recordHLSAcceptance
#endif
    }

}

enum SettingsApplyError: LocalizedError, Equatable {
    case noOutputSelected
    case invalidBandwidth

    var errorDescription: String? {
        switch self {
        case .noOutputSelected: "Select streaming, recording, or both"
        case .invalidBandwidth: "Measured upload bandwidth must be at least 1 Mbps"
        }
    }
}

final class Settings: Sendable {
    private static let credentialStore = KeychainCredentialStore()

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

    @discardableResult
    static func migrateLegacySettings() throws -> LegacySettingsMigrationResult {
        try LegacySettingsMigration.run(credentials: credentialStore)
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
    static var selectedPresetData: Data {
        get { UserDefaults.standard.data(forKey: "SelectedPreset") ?? Data() }
        set { UserDefaults.standard.set(newValue, forKey: "SelectedPreset") }
    }
    static var streamKey: String? {
        get {
            credential(.youTubeStreamKey)
        }
        set {
            setCredential(newValue, for: .youTubeStreamKey)
        }
    }
    static func loadStreamKey() throws -> String? {
        try credentialStore.value(for: .youTubeStreamKey)
    }
    static func setStreamKey(_ value: String?) throws {
        try credentialStore.setValue(value, for: .youTubeStreamKey)
    }
    static func setYouTubeAccessToken(_ value: String?) throws {
        try credentialStore.setValue(value, for: .youTubeAccessToken)
    }
    static func setYouTubeRefreshToken(_ value: String?) throws {
        try credentialStore.setValue(value, for: .youTubeRefreshToken)
    }
    static func clearYouTubeAuthorization() throws {
        try setYouTubeAccessToken(nil)
        try setYouTubeRefreshToken(nil)
        youtubeTokenExpiry = nil
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
    static var measuredBandwidth: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "MeasuredBandwidth")
            return value >= 1_000_000 ? value : 10_000_000
        }
        set { UserDefaults.standard.set(newValue, forKey: "MeasuredBandwidth") }
    }
    static var networkSharing: String {
        get { UserDefaults.standard.string(forKey: "NetworkSharing") ?? "many" }
        set { UserDefaults.standard.set(newValue, forKey: "NetworkSharing") }
    }
    static var cameraPosition: String {
        get { UserDefaults.standard.string(forKey: "CameraPosition") ?? "stationary" }
        set { UserDefaults.standard.set(newValue, forKey: "CameraPosition") }
    }
    static var journalError: Bool {
        get { bool(forKey: "JournalError", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "JournalError") }
    }
    static var journalWarning: Bool {
        get { bool(forKey: "JournalWarning", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "JournalWarning") }
    }
    static var journalInfo: Bool {
        get { bool(forKey: "JournalInfo", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "JournalInfo") }
    }
    static var journalDebug: Bool {
        get { bool(forKey: "JournalDebug", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "JournalDebug") }
    }
    static var selectedCamera: String {
        get {
            UserDefaults.standard.string(forKey: "SelectedCamera") ?? DEFAULT_CAMERA
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "SelectedCamera")
        }
    }
    static var selectedCameraID: String? {
        get { UserDefaults.standard.string(forKey: "SelectedCameraID") }
        set { UserDefaults.standard.set(newValue, forKey: "SelectedCameraID") }
    }
    static var selectedMicrophone: String? {
        get {
            UserDefaults.standard.string(forKey: "SelectedMicrophone")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "SelectedMicrophone")
        }
    }
    static var selectedMicrophoneID: String? {
        get { UserDefaults.standard.string(forKey: "SelectedMicrophoneID") }
        set { UserDefaults.standard.set(newValue, forKey: "SelectedMicrophoneID") }
    }
#if DEBUG
    static var captureRemuxFixtures: Bool {
        get {
            UserDefaults.standard.bool(forKey: "CaptureRemuxFixtures")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "CaptureRemuxFixtures")
        }
    }
    static var recordHLSAcceptance: Bool {
        get { UserDefaults.standard.bool(forKey: "RecordHLSAcceptance") }
        set { UserDefaults.standard.set(newValue, forKey: "RecordHLSAcceptance") }
    }
#endif
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
            credential(.youTubeAccessToken)
        }
        set {
            setCredential(newValue, for: .youTubeAccessToken)
        }
    }
    static var youtubeRefreshToken: String? {
        get {
            credential(.youTubeRefreshToken)
        }
        set {
            setCredential(newValue, for: .youTubeRefreshToken)
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

    private static func credential(_ credential: TubeistCredential) -> String? {
        do {
            return try credentialStore.value(for: credential)
        } catch {
            LOG("Could not read a credential from Keychain: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    private static func setCredential(_ value: String?, for credential: TubeistCredential) {
        do {
            try credentialStore.setValue(value, for: credential)
        } catch {
            LOG("Could not update a credential in Keychain: \(error.localizedDescription)", level: .error)
        }
    }
}
