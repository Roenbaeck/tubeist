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
    let bitrateLadder: BitrateLadder

    init(name: String, width: Int, height: Int, frameRate: Double, keyframeInterval: Double,
         audioChannels: Int, audioBitrate: Int, videoBitrate: Int) {
        self.name = name
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.keyframeInterval = keyframeInterval
        self.audioChannels = audioChannels
        self.audioBitrate = audioBitrate
        self.videoBitrate = videoBitrate
        let pixelsPerSecond = Double(width) * Double(height) * frameRate
        let floor = pixelsPerSecond.isFinite ? Int(max(250_000, min(Double(Int.max / 2), pixelsPerSecond * 0.015))) : 250_000
        bitrateLadder = BitrateLadder(maximum: videoBitrate, minimum: floor)
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try values.decode(String.self, forKey: .name),
                  width: try values.decode(Int.self, forKey: .width),
                  height: try values.decode(Int.self, forKey: .height),
                  frameRate: try values.decode(Double.self, forKey: .frameRate),
                  keyframeInterval: try values.decode(Double.self, forKey: .keyframeInterval),
                  audioChannels: try values.decode(Int.self, forKey: .audioChannels),
                  audioBitrate: try values.decode(Int.self, forKey: .audioBitrate),
                  videoBitrate: try values.decode(Int.self, forKey: .videoBitrate))
    }

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
    var scale: Double

    static let scaleRange = 0.25...2.0
    static func normalizedScale(_ value: Double) -> Double {
        value.isFinite ? min(scaleRange.upperBound, max(scaleRange.lowerBound, value)) : 1
    }

    init(url: String, scale: Double = 1) {
        self.url = url
        self.scale = Self.normalizedScale(scale)
    }

    enum CodingKeys: String, CodingKey { case url, scale }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decode(String.self, forKey: .url)
        // Existing saved overlays keep their original size.
        scale = Self.normalizedScale(try values.decodeIfPresent(Double.self, forKey: .scale) ?? 1)
    }
}

@Observable
class OverlaySettingsManager {
    // Persisted back to front. Appending puts a new overlay above existing ones.
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

@MainActor
private struct AppliedSettingsSnapshot {
    let streamKey: String?
    let stream: Bool
    let record: Bool
    let inputSyncsWithOutput: Bool
    let areSystemMetricsAtTop: Bool
    let measuredBandwidth: Int
    let networkSharing: String
    let cameraPosition: String
    let selectedPresetData: Data
    let journalError: Bool
    let journalWarning: Bool
    let journalInfo: Bool
    let journalDebug: Bool
    let selectedPlaylistID: String?
    let youtubeBroadcastPreferences: YouTubeBroadcastPreferences?
    let youtubeThumbnailData: Data?
    let overlays: [OverlaySetting]
    let overlayRefreshRate: OverlayRefreshRate
#if DEBUG
    let captureRemuxFixtures: Bool
    let recordHLSAcceptance: Bool
    let manualHLSEndingTest: Bool
#endif

    static func capture(overlays: [OverlaySetting]) throws -> Self {
#if DEBUG
        Self(
            streamKey: try Settings.loadStreamKey(),
            stream: Settings.stream,
            record: Settings.record,
            inputSyncsWithOutput: Settings.isInputSyncedWithOutput,
            areSystemMetricsAtTop: Settings.areSystemMetricsAtTop,
            measuredBandwidth: Settings.measuredBandwidth,
            networkSharing: Settings.networkSharing,
            cameraPosition: Settings.cameraPosition,
            selectedPresetData: Settings.selectedPresetData,
            journalError: Settings.journalError,
            journalWarning: Settings.journalWarning,
            journalInfo: Settings.journalInfo,
            journalDebug: Settings.journalDebug,
            selectedPlaylistID: Settings.youtubeSelectedPlaylistId,
            youtubeBroadcastPreferences: Settings.youtubeBroadcastPreferences,
            youtubeThumbnailData: try Settings.loadYouTubeThumbnailData(),
            overlays: overlays,
            overlayRefreshRate: Settings.overlayRefreshRate,
            captureRemuxFixtures: Settings.captureRemuxFixtures,
            recordHLSAcceptance: Settings.recordHLSAcceptance,
            manualHLSEndingTest: Settings.manualHLSEndingTest
        )
#else
        Self(
            streamKey: try Settings.loadStreamKey(),
            stream: Settings.stream,
            record: Settings.record,
            inputSyncsWithOutput: Settings.isInputSyncedWithOutput,
            areSystemMetricsAtTop: Settings.areSystemMetricsAtTop,
            measuredBandwidth: Settings.measuredBandwidth,
            networkSharing: Settings.networkSharing,
            cameraPosition: Settings.cameraPosition,
            selectedPresetData: Settings.selectedPresetData,
            journalError: Settings.journalError,
            journalWarning: Settings.journalWarning,
            journalInfo: Settings.journalInfo,
            journalDebug: Settings.journalDebug,
            selectedPlaylistID: Settings.youtubeSelectedPlaylistId,
            youtubeBroadcastPreferences: Settings.youtubeBroadcastPreferences,
            youtubeThumbnailData: try Settings.loadYouTubeThumbnailData(),
            overlays: overlays,
            overlayRefreshRate: Settings.overlayRefreshRate
        )
#endif
    }

    func restore(overlays manager: OverlaySettingsManager) async throws {
        try Settings.setStreamKey(streamKey)
        Settings.stream = stream
        Settings.record = record
        Settings.isInputSyncedWithOutput = inputSyncsWithOutput
        Settings.areSystemMetricsAtTop = areSystemMetricsAtTop
        Settings.measuredBandwidth = measuredBandwidth
        Settings.networkSharing = networkSharing
        Settings.cameraPosition = cameraPosition
        Settings.selectedPresetData = selectedPresetData
        Settings.journalError = journalError
        Settings.journalWarning = journalWarning
        Settings.journalInfo = journalInfo
        Settings.journalDebug = journalDebug
        Settings.youtubeSelectedPlaylistId = selectedPlaylistID
        Settings.youtubeBroadcastPreferences = youtubeBroadcastPreferences
        try Settings.setYouTubeThumbnailData(youtubeThumbnailData)
        manager.replaceOverlays(with: overlays)
        Settings.overlayRefreshRate = overlayRefreshRate
#if DEBUG
        Settings.captureRemuxFixtures = captureRemuxFixtures
        Settings.recordHLSAcceptance = recordHLSAcceptance
        Settings.manualHLSEndingTest = manualHLSEndingTest
#endif
        await Settings.configureJournal()
    }
}

private struct YouTubeSettingsLoadContext: Equatable {
    let streamKey: String
    let isSignedIn: Bool
    let streamingEnabled: Bool
}

struct SettingsView: View {
    var overlayManager: OverlaySettingsManager
    @Environment(AppState.self) var appState
    @Environment(\.presentationMode) private var presentationMode
    @State private var stream: Bool = Settings.stream
    @State private var record: Bool = Settings.record
    @State private var inputSyncsWithOutput: Bool = Settings.isInputSyncedWithOutput
    @State private var areSystemMetricsAtTop = Settings.areSystemMetricsAtTop
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
    @State private var manualHLSEndingTest: Bool = Settings.manualHLSEndingTest
#endif
    @State private var newOverlayURL: String = ""
    @State private var selectedPreset: Preset? = nil
    @State private var didInitializeDraft = false
    @State private var hasCustomDraft = false
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
    @State private var youtubeDraft = YouTubeSettingsDraft()
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var isSettingUpYouTubeStream = false
    @State private var youtubeConfigLoaded: Bool = false
    @State private var lastYouTubeLoadContext: YouTubeSettingsLoadContext?
    @State private var youtubeLoadGeneration = UUID()
    @State private var isYouTubeRefreshCoolingDown: Bool = false
    @State private var editingOverlay: OverlaySetting? = nil
    @State private var editedOverlayURL: String = ""
    @State private var editedOverlayScale: Double = 1
    @State private var overlayEditError: String?
    // Settings presents the stack front to back, with the top layer first.
    @State private var overlayDraft: [OverlaySetting] = []
    @State private var showingOverlayOrder = false
    @State private var overlayRefreshRate = Settings.overlayRefreshRate
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
        
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

                Section(header: Text("YouTube Streaming and Recording"), footer: Text("Sign in below to set up YouTube streaming, or enter an existing HLS stream key. You can also save an original-quality recording on this phone.")) {
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

                if stream {
                    if youtubeService.isSignedIn {
                        Section(
                            header: Text("Tubeist Stream Key"),
                            footer: Text("Tubeist can create and manage a reusable HLS stream key for your signed-in channel. Choosing this replaces the key above; tap Save to use it. You can keep your existing key if it already works. Existing YouTube streams are kept.")
                        ) {
                            Button(streamKeyManager.currentKey.isEmpty ? "Create stream key" : "Use a Tubeist stream key") {
                                Task { await setUpYouTubeStream() }
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("Set up YouTube stream")
                            .disabled(youtubeService.isLoading || isSettingUpYouTubeStream)
                        }
                    }

                    Section(header: Text("YouTube Stream Configuration"), footer: Text(youtubeService.isSignedIn ? "Save keeps broadcast preferences in Tubeist; your broadcast is created or updated when you tap Start stream." : "Sign in with your Google account to set up a stream key and broadcast without YouTube Studio. Your channel must already be enabled for live streaming.")) {
                        if !youtubeService.isSignedIn {
                            Button("Sign in with Google") {
                                Task {
                                    await youtubeService.signIn()
                                    if youtubeService.isSignedIn {
                                        appState.isYouTubeSignedIn = true
                                    }
                                }
                            }
                        } else {
                            if youtubeService.isLoading || isSettingUpYouTubeStream {
                                HStack {
                                    ProgressView()
                                    Text("Loading...")
                                        .foregroundColor(.secondary)
                                }
                            } else if youtubeDraft.broadcast != nil {
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

                                TextField("Stream Title", text: $youtubeDraft.title)
                                    .autocapitalization(.sentences)

                                Picker("Visibility", selection: $youtubeDraft.visibility) {
                                    Text("Public").tag("public")
                                    Text("Unlisted").tag("unlisted")
                                    Text("Private").tag("private")
                                }

                                Toggle("Made for kids", isOn: $youtubeDraft.madeForKids)
                                Toggle("DVR (viewers can rewind)", isOn: $youtubeDraft.enableDvr)
                                Picker("Latency", selection: $youtubeDraft.latencyPreference) {
                                    Text("Normal").tag("normal")
                                    Text("Low").tag("low")
                                    Text("Ultra-low").tag("ultraLow")
                                }

                                let previewThumbnail = youtubeDraft.thumbnail.image
                                let isLoadingThumbnail = youtubeDraft.thumbnail.isLoading
                                PhotosPicker(selection: thumbnailSelection, matching: .images) {
                                    HStack {
                                        Text("Thumbnail")
                                        if isLoadingThumbnail {
                                            ProgressView().accessibilityLabel("Loading thumbnail")
                                        }
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
                                if let error = youtubeDraft.thumbnail.errorMessage {
                                    Text(error).foregroundColor(.red)
                                    Button("Retry thumbnail") {
                                        loadSelectedThumbnail()
                                    }
                                }

                                Picker("Playlist", selection: $youtubeDraft.playlistId) {
                                    Text("None").tag(String?.none)
                                    ForEach(youtubeDraft.playlists) { playlist in
                                        Text(playlist.title).tag(Optional(playlist.id))
                                    }
                                }
                                if let errorMessage = youtubeService.errorMessage {
                                    Text(errorMessage).foregroundColor(.red)
                                    Text("Your unsaved changes are kept. Refresh to try again.")
                                        .foregroundColor(.secondary)
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
                                Text("Set up a Tubeist stream key above, or enter an existing HLS key.")
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
                }

#if DEBUG
                Section(
                    header: Text("YouTube HLS Development"),
                    footer: Text("Diagnostic recording saves upload events and the exact video segments and playlists in Tubeist’s Files folder, up to 512 MB per stream. Use it for short test streams and delete the files afterward. Stream keys are not saved. Fixture capture separately saves one remux sample set.")
                ) {
                    Toggle("Capture fMP4 remux fixtures", isOn: $captureRemuxFixtures)
                    Toggle("Record YouTube HLS diagnostics", isOn: $recordHLSAcceptance)
                }
                Section(
                    header: Text("Stream Ending Test"),
                    footer: Text("Requires YouTube sign-in. Stop uploads all remaining media but leaves the broadcast open, with automatic ending disabled. Wait for the final words in the YouTube player, then end the broadcast manually in YouTube Studio. The YouTube indicator stays red until the broadcast ends. Diagnostics are recorded automatically. Turn this off for normal streams.")
                ) {
                    Toggle("End broadcast manually in Studio", isOn: $manualHLSEndingTest)
                        .accessibilityIdentifier("manualHLSEndingTestToggle")
                }
#endif

                Section(header: Text("Camera"), footer: Text("Select if the camera will be moving around with altering scenery or remain stationary aimed at a single scene. If you do not want to get suggested presets and instead configure settings in detail, select 'Custom' here.")) {
                    Picker("Camera Position", selection: cameraPositionBinding) {
                        Text("Stationary").tag("stationary")
                        Text("Moving").tag("moving")
                        Text("Custom").tag("custom")
                    }
                    .pickerStyle(.segmented)
                }
                
                // Figure out "sane" presets given some additional information, unless the user wants a custom mode
                if cameraPosition != "custom" {
                    Section(header: Text("Bandwidth"), footer: Text("Enter the upload speed in Mbps shown at https://speed.cloudflare.com.")) {
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
                        Picker(selection: Binding(get: { selectedPreset }, set: { preset in
                            if let preset { selectPreset(preset) }
                        })) {
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
                
                Section {
                    ForEach(overlayDraft) { overlay in
                        Button {
                            editingOverlay = overlay
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(overlay.url)
                                        .foregroundColor(.primary)
                                        .multilineTextAlignment(.leading)
                                    if overlay.scale != 1 {
                                        Text("Scale: \(Int((overlay.scale * 100).rounded()))%")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "pencil")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .accessibilityIdentifier("edit-overlay-\(overlay.id)")
                    }
                    .onDelete { offsets in
                        overlayDraft.remove(atOffsets: offsets)
                    }
                    
                    HStack {
                        TextField("New Overlay URL", text: $newOverlayURL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .onSubmit(addOverlay)
                        Button(action: addOverlay) {
                            Image(systemName: "plus.circle.fill")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Add overlay")
                    }
                    Button("Reorder overlays") { showingOverlayOrder = true }
                        .disabled(overlayDraft.count < 2)
                        .accessibilityIdentifier("reorder-overlays")
                } header: {
                    Text("Overlays")
                } footer: {
                    Text("The top overlay in this list appears in front in both INPUT and OUTPUT. New overlays are added on top. Tap an overlay to edit its URL or scale, or Reorder overlays to change the stack. Save to apply your changes. Audio is captured from the last playing overlay if audio from multiple overlays overlap.")
                }

                Section {
                    Picker("Maximum refresh rate", selection: $overlayRefreshRate) {
                        ForEach(OverlayRefreshRate.allCases) { rate in
                            Text(rate.label).tag(rate)
                        }
                    }
                    .accessibilityIdentifier("overlay-refresh-rate")
                } header: {
                    Text("Overlay Refresh")
                } footer: {
                    Text("Applies to output, streaming, and recording. 1 update/second captures page changes and saves battery. 3, 10, and 30 updates/second also capture animations but use more power. Updates slow down if the phone cannot keep up. The input view renders the web page live.")
                }

                Section(header: Text("Monitoring")) {
                    Picker("System health bar position", selection: $areSystemMetricsAtTop) {
                        Text("Bottom").tag(false)
                        Text("Top").tag(true)
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
            .disabled(isSaving)
            // Form sections are recreated while scrolling. Keep discovery on
            // the screen itself, and retain the draft for an unchanged context.
            .task(id: youtubeLoadContext) {
                let context = youtubeLoadContext
                guard !isSettingUpYouTubeStream, context != lastYouTubeLoadContext else { return }
                updateYouTubeDraftContext()
                youtubeLoadGeneration = UUID()
                guard context.streamingEnabled, context.isSignedIn, !context.streamKey.isEmpty else {
                    lastYouTubeLoadContext = context
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(400))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await loadYouTubeBroadcast(forStreamKey: context.streamKey)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button("Cancel") {
                presentationMode.wrappedValue.dismiss()
            }.disabled(isSaving || isSettingUpYouTubeStream), trailing: Button("Save") {
                Task {
                    isSaving = true
                    defer { isSaving = false }
                    var previousSettings: AppliedSettingsSnapshot?
                    var localSettingsCommitted = false
                    do {
                        try validateDraft()
                        // Save also includes an unsubmitted URL still in the
                        // text field; Return and the plus button are optional.
                        addOverlay()
                        previousSettings = try AppliedSettingsSnapshot.capture(
                            overlays: overlayManager.overlays
                        )
                        if cameraPosition == "custom" {
                            saveCustomPreset()
                        }
                        try commitDraft()
                        localSettingsCommitted = true
                        if youtubeDraft.broadcast != nil && youtubeService.isSignedIn {
                            try saveYouTubePreferences()
                        }
                        try await Streamer.shared.cycleSessions()
                        await Settings.configureJournal()
                        youtubeService.errorMessage = nil
                        saveErrorMessage = nil
                        presentationMode.wrappedValue.dismiss()
                    } catch {
                        var failureMessage = error.localizedDescription
                        if localSettingsCommitted, let previousSettings {
                            do {
                                try await previousSettings.restore(overlays: overlayManager)
                                try await Streamer.shared.cycleSessions()
                                failureMessage += " Local app settings were restored."
                            } catch {
                                failureMessage += " Restoring the previous app settings also failed: \(error.localizedDescription)"
                            }
                        }
                        youtubeService.errorMessage = failureMessage
                        saveErrorMessage = failureMessage
                        LOG("Could not save settings: \(error.localizedDescription)", level: .error)
                    }
                }
            }
            .disabled(isSaving || isSettingUpYouTubeStream || youtubeDraft.thumbnail.isLoading)
            .buttonStyle(.borderedProminent))
            .interactiveDismissDisabled(isSaving || isSettingUpYouTubeStream)
            .onAppear {
                guard !didInitializeDraft else { return }
                didInitializeDraft = true
                overlayDraft = Array(overlayManager.overlays.reversed())
                if let preset = try? JSONDecoder().decode(Preset.self, from: selectedPresetData) {
                    selectedPreset = preset
                } else {
                    selectedPreset = nil
                }
                if let preset = selectedPreset, preset.name == "Custom" {
                    loadCustomPreset(preset)
                }
                if cameraPosition != "custom" {
                    selectPreset(.forCameraPosition(cameraPosition, matching: selectedPreset ?? defaultPreset))
                }
            }
            .onDisappear {
                youtubeLoadGeneration = UUID()
                youtubeDraft.thumbnail.cancelLoading()
            }
            .alert(
                "Could Not Save Settings",
                isPresented: Binding(
                    get: { saveErrorMessage != nil },
                    set: { if !$0 { saveErrorMessage = nil } }
                )
            ) {
                Button("OK") { saveErrorMessage = nil }
            } message: {
                Text(saveErrorMessage ?? "The settings could not be saved")
            }
            .sheet(item: $editingOverlay) { overlay in
                NavigationStack {
                    Form {
                        Section(footer: Text("Update the existing overlay URL. Swipe left on the overlay row to delete it instead.")) {
                            TextField("Overlay URL", text: $editedOverlayURL)
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .onChange(of: editedOverlayURL) { _, _ in overlayEditError = nil }
                                .onSubmit { saveOverlayEdit(for: overlay) }
                            if let overlayEditError {
                                Text(overlayEditError).foregroundColor(.red)
                            }
                        }
                        Section {
                            HStack {
                                Text("Scale")
                                Spacer()
                                Text("\(Int((editedOverlayScale * 100).rounded()))%")
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $editedOverlayScale, in: OverlaySetting.scaleRange, step: 0.05)
                                .accessibilityLabel("Overlay scale")
                                .accessibilityValue("\(Int((editedOverlayScale * 100).rounded())) percent")
                                .accessibilityIdentifier("overlay-scale")
                            Button("Reset to 100%") { editedOverlayScale = 1 }
                        } header: {
                            Text("Overlay Size")
                        } footer: {
                            Text("Reduce the scale to fit a large scoreboard or web page. Applies to this overlay in both monitors, the stream, and recordings. 100% keeps the original size.")
                        }
                    }
                    .navigationTitle("Edit Overlay")
                    .navigationBarTitleDisplayMode(.inline)
                    .onAppear {
                        // Initialize from the presented item. A sheet's first
                        // render can otherwise use stale values from its parent.
                        editedOverlayURL = overlay.url
                        editedOverlayScale = overlay.scale
                        overlayEditError = nil
                    }
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
            .sheet(isPresented: $showingOverlayOrder) {
                OverlayOrderView(overlays: $overlayDraft)
            }
        }
    }

    private var youtubeLoadContext: YouTubeSettingsLoadContext {
        YouTubeSettingsLoadContext(
            streamKey: streamKeyManager.currentKey,
            isSignedIn: youtubeService.isSignedIn,
            streamingEnabled: stream
        )
    }

    private var streamKeyBinding: Binding<String> {
        Binding(
            get: { streamKeyManager.currentKey },
            set: {
                streamKeyManager.updateKey($0)
                updateYouTubeDraftContext()
            }
        )
    }

    private var thumbnailSelection: Binding<PhotosPickerItem?> {
        Binding(get: { selectedPhotoItem }, set: { item in
            selectedPhotoItem = item
            loadSelectedThumbnail()
        })
    }

    private func loadSelectedThumbnail() {
        guard let selectedPhotoItem else { return }
        youtubeDraft.thumbnail.select {
            try await selectedPhotoItem.loadTransferable(type: Data.self)
        }
    }

    private var cameraPositionBinding: Binding<String> {
        Binding(get: { cameraPosition }, set: { position in
            guard position != cameraPosition else { return }
            let current = cameraPosition == "custom" ? customPreset : selectedPreset ?? defaultPreset
            if position == "custom" {
                if !hasCustomDraft { loadCustomPreset(current) }
            } else {
                selectPreset(.forCameraPosition(position, matching: current))
            }
            cameraPosition = position
        })
    }

    private func selectPreset(_ preset: Preset) {
        selectedPreset = preset
        if let encoded = try? JSONEncoder().encode(preset) { selectedPresetData = encoded }
    }

    private func loadCustomPreset(_ preset: Preset) {
        hasCustomDraft = true
        customResolution = Resolution(preset.width, preset.height)
        customFrameRate = preset.frameRate
        customKeyframeInterval = preset.keyframeInterval
        customAudioChannels = preset.audioChannels
        customAudioBitrate = preset.audioBitrate
        customVideoBitrate = preset.videoBitrate
    }

    private var broadcastId: String? {
        guard let id = youtubeDraft.broadcast?.id, !id.isEmpty else { return nil }
        return id
    }

    private var broadcastLifeCycleStatus: String? { youtubeDraft.broadcast?.lifeCycleStatus }

    private func clearYouTubeAccountState() {
        guard youtubeService.signOut() else { return }
        resetLoadedYouTubeBroadcast()
        appState.isYouTubeSignedIn = false
    }

    private var customPreset: Preset {
        Preset(
            name: "Custom",
            width: customResolution.width,
            height: customResolution.height,
            frameRate: customFrameRate,
            keyframeInterval: customKeyframeInterval,
            audioChannels: customAudioChannels,
            audioBitrate: customAudioBitrate,
            videoBitrate: customVideoBitrate
        )
    }

    func saveCustomPreset() {
        selectPreset(customPreset)
    }
    
    func addOverlay() {
        let trimmedURL = newOverlayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OverlayURLValidator.isAllowed(trimmedURL) else { return }
        if !overlayDraft.contains(where: { $0.url == trimmedURL }) {
            overlayDraft.insert(OverlaySetting(url: trimmedURL), at: 0)
        }
        newOverlayURL = ""
    }

    func saveOverlayEdit(for overlay: OverlaySetting) {
        let trimmedURL = editedOverlayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OverlayURLValidator.isAllowed(trimmedURL) else {
            overlayEditError = SettingsSaveError.invalidOverlayURL.localizedDescription
            return
        }
        guard !overlayDraft.contains(where: { $0.id != overlay.id && $0.url == trimmedURL }) else {
            overlayEditError = "An overlay with this URL already exists. Enter a different URL."
            return
        }
        guard let index = overlayDraft.firstIndex(where: { $0.id == overlay.id }) else {
            overlayEditError = "This overlay is no longer in the list. Close the editor and add it again."
            return
        }
        overlayDraft[index].url = trimmedURL
        overlayDraft[index].scale = OverlaySetting.normalizedScale(editedOverlayScale)
        overlayEditError = nil
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
        lastYouTubeLoadContext = nil
        youtubeLoadGeneration = UUID()
        youtubeDraft.reset()
        selectedPhotoItem = nil
        youtubeConfigLoaded = false
        youtubeService.errorMessage = nil
        appState.youtubeBroadcastId = nil
        appState.youtubeStatus = nil
    }

    private func updateYouTubeDraftContext() {
        let key = youtubeService.isSignedIn ? streamKeyManager.currentKey : nil
        if youtubeDraft.streamKey != key {
            resetLoadedYouTubeBroadcast()
            youtubeDraft.useStreamKey(key)
        }
    }

    private func setUpYouTubeStream() async {
        guard !isSettingUpYouTubeStream, !youtubeService.isLoading else { return }
        isSettingUpYouTubeStream = true
        defer { isSettingUpYouTubeStream = false }
        do {
            let stream = try await youtubeService.setUpStream()
            // Stream keys remain drafts until Save writes them to Keychain.
            streamKeyManager.updateKey(stream.streamName)
            await loadYouTubeBroadcast(forStreamKey: stream.streamName)
        } catch {
            youtubeService.errorMessage = YouTubeDiagnostics.text(error.localizedDescription, secrets: [
                streamKeyManager.currentKey, Settings.youtubeAccessToken ?? "", Settings.youtubeRefreshToken ?? ""
            ])
        }
    }

    func loadYouTubeBroadcast(forStreamKey requestedStreamKey: String? = nil) async {
        let streamKey = requestedStreamKey ?? streamKeyManager.currentKey
        guard !streamKey.isEmpty else {
            resetLoadedYouTubeBroadcast()
            return
        }
        updateYouTubeDraftContext()
        youtubeLoadGeneration = UUID()
        youtubeService.errorMessage = nil
        let generation = youtubeLoadGeneration
        let context = youtubeLoadContext
        do {
            let configuration = try await youtubeService.loadSettingsConfiguration(forStreamKey: streamKey)
            let broadcast = configuration.broadcast
            let loadedPlaylists = configuration.playlists
            guard generation == youtubeLoadGeneration, context == youtubeLoadContext,
                  streamKey == streamKeyManager.currentKey, !Task.isCancelled else {
                return
            }
            let previousStreamId = youtubeDraft.broadcast?.boundStreamId
            youtubeDraft.apply(
                broadcast: broadcast,
                playlists: loadedPlaylists,
                savedPreferences: Settings.youtubeBroadcastPreferences,
                savedThumbnail: try? Settings.loadYouTubeThumbnailData()
            )
            if previousStreamId != broadcast.boundStreamId { selectedPhotoItem = nil }
            appState.youtubeBroadcastId = broadcastId
            appState.youtubeStatus = broadcastId == nil ? nil : broadcast.lifeCycleStatus
            youtubeConfigLoaded = true
            lastYouTubeLoadContext = context
            youtubeService.errorMessage = nil
            LOG("Loaded YouTube broadcast: \(broadcast.title)", level: .debug)
        } catch {
            guard generation == youtubeLoadGeneration, context == youtubeLoadContext,
                  streamKey == streamKeyManager.currentKey, !Task.isCancelled else {
                return
            }
            let message = YouTubeDiagnostics.text(error.localizedDescription, secrets: [
                streamKey, Settings.youtubeAccessToken ?? "", Settings.youtubeRefreshToken ?? "",
            ])
            youtubeService.errorMessage = message
            youtubeConfigLoaded = true
            lastYouTubeLoadContext = context
            LOG("Failed to load YouTube configuration: \(message)", level: .error)
        }
    }

    func saveYouTubePreferences() throws {
        guard youtubeDraft.streamKey == streamKeyManager.currentKey,
              let currentBroadcast = youtubeDraft.broadcast else { return }
        guard let streamId = currentBroadcast.boundStreamId else {
            throw YouTubeError.invalidResponse
        }
        let previousPreferences = Settings.youtubeBroadcastPreferences
        Settings.youtubeBroadcastPreferences = YouTubeBroadcastPreferences(
            streamId: streamId,
            title: youtubeDraft.title,
            privacyStatus: youtubeDraft.visibility,
            enableDvr: youtubeDraft.enableDvr,
            latencyPreference: youtubeDraft.latencyPreference,
            enableMonitorStream: currentBroadcast.enableMonitorStream,
            broadcastStreamDelayMs: currentBroadcast.broadcastStreamDelayMs,
            enableEmbed: currentBroadcast.enableEmbed,
            recordFromStart: currentBroadcast.recordFromStart,
            enableAutoStart: currentBroadcast.enableAutoStart,
            // YouTube owns completion after Tubeist closes HLS ingestion.
            enableAutoStop: true,
            playlistId: youtubeDraft.playlistId,
            selfDeclaredMadeForKids: youtubeDraft.madeForKids
        )

        if youtubeDraft.thumbnail.hasNewSelection,
           let thumbnailImage = youtubeDraft.thumbnail.image,
           let resized = thumbnailImage.scaledToFit(maxWidth: 1280, maxHeight: 720) {
            guard let imageData = resized.jpegDataWithinLimit(maxBytes: 2_000_000) else {
                throw YouTubeError.thumbnailTooLarge
            }
            try Settings.setYouTubeThumbnailData(imageData)
        } else if previousPreferences?.streamId != streamId {
            try Settings.setYouTubeThumbnailData(nil)
        }
        Settings.youtubeSelectedPlaylistId = youtubeDraft.playlistId
        LOG("Saved YouTube preferences for the next stream", level: .debug)
    }

    private func validateDraft() throws {
        guard !youtubeDraft.thumbnail.isLoading else { throw SettingsSaveError.thumbnailLoading }
        let pendingOverlayURL = newOverlayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pendingOverlayURL.isEmpty || OverlayURLValidator.isAllowed(pendingOverlayURL) else {
            throw SettingsSaveError.invalidOverlayURL
        }
        guard stream || record else {
            throw SettingsSaveError.noOutputSelected
        }
        if stream {
            guard !streamKeyManager.currentKey.isEmpty else {
                throw StreamStartError.missingStreamKey
            }
            _ = try YouTubeHLSEndpoint.manualPrimary(streamKey: streamKeyManager.currentKey)
        }
        guard measuredBandwidth >= 1_000_000 else {
            throw SettingsSaveError.invalidBandwidth
        }
    }

    private func commitDraft() throws {
        try streamKeyManager.commit()
        Settings.stream = stream
        Settings.record = record
        Settings.isInputSyncedWithOutput = inputSyncsWithOutput
        Settings.areSystemMetricsAtTop = areSystemMetricsAtTop
        Settings.measuredBandwidth = measuredBandwidth
        Settings.networkSharing = networkSharing
        Settings.cameraPosition = cameraPosition
        Settings.selectedPresetData = selectedPresetData
        Settings.journalError = journalError
        Settings.journalWarning = journalWarning
        Settings.journalInfo = journalInfo
        Settings.journalDebug = journalDebug
        overlayManager.replaceOverlays(with: Array(overlayDraft.reversed()))
        Settings.overlayRefreshRate = overlayRefreshRate
#if DEBUG
        Settings.captureRemuxFixtures = captureRemuxFixtures
        Settings.recordHLSAcceptance = recordHLSAcceptance
        Settings.manualHLSEndingTest = manualHLSEndingTest
#endif
    }

}

enum SettingsSaveError: LocalizedError, Equatable {
    case noOutputSelected
    case invalidBandwidth
    case invalidOverlayURL
    case thumbnailLoading

    var errorDescription: String? {
        switch self {
        case .noOutputSelected: "Select streaming, recording, or both"
        case .invalidBandwidth: "Measured upload bandwidth must be at least 1 Mbps"
        case .invalidOverlayURL: "Enter a valid overlay URL starting with http:// or https://"
        case .thumbnailLoading: "Wait for the thumbnail to finish loading before saving"
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

    static func journalLevels(in defs: UserDefaults = .standard) -> Set<LogLevel> {
        let journalError = defs.object(forKey: "JournalError") != nil ? defs.bool(forKey: "JournalError") : true
        let journalWarning = defs.object(forKey: "JournalWarning") != nil ? defs.bool(forKey: "JournalWarning") : true
        let journalInfo = defs.object(forKey: "JournalInfo") != nil ? defs.bool(forKey: "JournalInfo") : true
        let journalDebug = defs.object(forKey: "JournalDebug") != nil ? defs.bool(forKey: "JournalDebug") : false
        var levels: Set<LogLevel> = []
        if journalError { levels.insert(.error) }
        if journalWarning { levels.insert(.warning) }
        if journalInfo { levels.insert(.info) }
        if journalDebug { levels.insert(.debug) }
        return levels
    }

    static func configureJournal() async {
        await Journal.shared.setLevels(journalLevels())
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
    // These are AVAudioSession port UIDs, not the legacy AVCaptureDevice ID.
    // Existing installations default to Automatic rather than accidentally
    // pinning the built-in mic based on an old "iPhone Microphone" label.
    static var audioInputPortID: String? {
        get { UserDefaults.standard.string(forKey: "AudioInputPortID") }
        set { UserDefaults.standard.set(newValue, forKey: "AudioInputPortID") }
    }
    static var audioInputPortName: String? {
        get { UserDefaults.standard.string(forKey: "AudioInputPortName") }
        set { UserDefaults.standard.set(newValue, forKey: "AudioInputPortName") }
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
    static var manualHLSEndingTest: Bool {
        get { UserDefaults.standard.bool(forKey: "ManualHLSEndingTest") }
        set { UserDefaults.standard.set(newValue, forKey: "ManualHLSEndingTest") }
    }
#endif
    static var hlsStreamEndingPolicy: HLSStreamEndingPolicy {
#if DEBUG
        manualHLSEndingTest ? .manualDiagnostic : .automatic
#else
        .automatic
#endif
    }
    static var cameraStabilization: String? {
        get {
            UserDefaults.standard.string(forKey: "CameraStabilization")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "CameraStabilization")
        }
    }
    static var showHorizonLevel: Bool {
        get { UserDefaults.standard.bool(forKey: "ShowHorizonLevel") }
        set { UserDefaults.standard.set(newValue, forKey: "ShowHorizonLevel") }
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
    static var overlayRefreshRate: OverlayRefreshRate {
        get { OverlayRefreshRate.stored(UserDefaults.standard.integer(forKey: "OverlayRefreshRate")) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "OverlayRefreshRate") }
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
    static var youtubeBroadcastPreferences: YouTubeBroadcastPreferences? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "YouTubeBroadcastPreferences") else {
                return nil
            }
            return try? JSONDecoder().decode(YouTubeBroadcastPreferences.self, from: data)
        }
        set {
            let data = newValue.flatMap { try? JSONEncoder().encode($0) }
            UserDefaults.standard.set(data, forKey: "YouTubeBroadcastPreferences")
        }
    }

    static func loadYouTubeThumbnailData() throws -> Data? {
        let fileManager = FileManager.default
        let url = try youtubeThumbnailURL(fileManager: fileManager, createDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    static func setYouTubeThumbnailData(_ data: Data?) throws {
        let fileManager = FileManager.default
        let url = try youtubeThumbnailURL(fileManager: fileManager, createDirectory: data != nil)
        if let data {
            try data.write(to: url, options: .atomic)
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private static func youtubeThumbnailURL(
        fileManager: FileManager,
        createDirectory: Bool
    ) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = applicationSupport.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "Tubeist",
            isDirectory: true
        )
        if createDirectory {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory.appendingPathComponent("youtube-broadcast-thumbnail.jpg")
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
