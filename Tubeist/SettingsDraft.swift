import Foundation
import Observation
import UIKit

extension Preset {
    static func forCameraPosition(_ position: String, matching preset: Preset) -> Preset {
        let presets = position == "moving" ? movingCameraPresets : stationaryCameraPresets
        return presets.first { $0.width == preset.width && $0.height == preset.height }
            ?? presets.first { $0.width == DEFAULT_COMPRESSED_WIDTH && $0.height == DEFAULT_COMPRESSED_HEIGHT }!
    }
}

/// A selection becomes part of the draft only after it has finished loading.
@MainActor @Observable
final class SettingsThumbnailDraft {
    private(set) var image: UIImage?
    private(set) var hasNewSelection = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?

    @discardableResult
    func select(load: @escaping @MainActor () async throws -> Data?) -> Task<Void, Never> {
        cancelLoading()
        let selection = generation
        isLoading = true
        errorMessage = nil
        let task = Task { @MainActor in
            do {
                let data = try await load()
                guard selection == generation, !Task.isCancelled else { return }
                guard let data, let image = UIImage(data: data) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                self.image = image
                hasNewSelection = true
            } catch {
                guard selection == generation, !Task.isCancelled else { return }
                errorMessage = "Could not load this image. Your previous thumbnail has been kept. Try again or select another image."
            }
            isLoading = false
            self.task = nil
        }
        self.task = task
        return task
    }

    func cancelLoading() {
        task?.cancel()
        task = nil
        generation = UUID()
        isLoading = false
    }

    func reset(image: UIImage? = nil) {
        cancelLoading()
        self.image = image
        hasNewSelection = false
        errorMessage = nil
    }
}

/// Remote status may change while local edits remain staged until Save.
@MainActor @Observable
final class YouTubeSettingsDraft {
    private(set) var streamKey: String?
    private(set) var broadcast: YouTubeBroadcast?
    private(set) var playlists: [YouTubePlaylist] = []
    var title = ""
    var visibility = "public"
    var enableDvr = true
    var enableEmbed = false
    var madeForKids = false
    var latencyPreference = "normal"
    var playlistId: String?
    let thumbnail = SettingsThumbnailDraft()

    /// Recording mode is deliberately absent: hiding YouTube must not erase edits.
    func useStreamKey(_ key: String?) {
        guard key != streamKey else { return }
        reset()
        streamKey = key
    }

    func reset() {
        streamKey = nil
        broadcast = nil
        playlists = []
        title = ""
        visibility = "public"
        enableDvr = true
        enableEmbed = false
        madeForKids = false
        latencyPreference = "normal"
        playlistId = nil
        thumbnail.reset()
    }

    func apply(broadcast: YouTubeBroadcast, playlists: [YouTubePlaylist],
               savedPreferences: YouTubeBroadcastPreferences?, savedThumbnail: Data?) {
        let sameStream = self.broadcast != nil && broadcast.boundStreamId != nil
            && self.broadcast?.boundStreamId == broadcast.boundStreamId
        if !sameStream {
            let preferences = savedPreferences?.streamId == broadcast.boundStreamId ? savedPreferences : nil
            title = preferences?.title ?? broadcast.title
            visibility = preferences?.privacyStatus ?? broadcast.privacyStatus
            enableDvr = preferences?.enableDvr ?? broadcast.enableDvr
            enableEmbed = preferences?.enableEmbed ?? broadcast.enableEmbed
            madeForKids = preferences?.selfDeclaredMadeForKids ?? broadcast.selfDeclaredMadeForKids ?? false
            latencyPreference = preferences?.latencyPreference ?? broadcast.latencyPreference
            playlistId = preferences?.playlistId
            thumbnail.reset(image: preferences == nil ? nil : savedThumbnail.flatMap { UIImage(data: $0) })
        }
        self.broadcast = broadcast
        self.playlists = playlists
        if let playlistId, !playlists.contains(where: { $0.id == playlistId }) {
            self.playlistId = nil
        }
    }

    /// Options without a Settings control keep the loaded broadcast's values.
    func preferences() -> YouTubeBroadcastPreferences? {
        guard let broadcast, let streamId = broadcast.boundStreamId else { return nil }
        return YouTubeBroadcastPreferences(
            streamId: streamId,
            title: title,
            privacyStatus: visibility,
            enableDvr: enableDvr,
            latencyPreference: latencyPreference,
            enableMonitorStream: broadcast.enableMonitorStream,
            broadcastStreamDelayMs: broadcast.broadcastStreamDelayMs,
            enableEmbed: enableEmbed,
            recordFromStart: broadcast.recordFromStart,
            enableAutoStart: broadcast.enableAutoStart,
            // YouTube owns completion after Tubeist closes HLS ingestion.
            enableAutoStop: true,
            playlistId: playlistId,
            selfDeclaredMadeForKids: madeForKids
        )
    }
}
