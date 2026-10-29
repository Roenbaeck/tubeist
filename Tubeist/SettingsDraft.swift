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

enum PlannedStreamChoice: Hashable, Sendable {
    case newStream
    case planned(String)
    case restart
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

    private(set) var plannedBroadcasts: [YouTubeBroadcast] = []
    private(set) var plannedNeedsOwnKey: Set<String> = []
    private(set) var restartSelection: PlannedStreamSelection?
    private(set) var plannedChoice: PlannedStreamChoice = .newStream
    let plannedThumbnail = SettingsThumbnailDraft()

    private struct Fields {
        var title: String
        var visibility: String
        var madeForKids: Bool
        var enableDvr: Bool
        var enableEmbed: Bool
        var latencyPreference: String
        var playlistId: String?
    }
    /// The template's fields while a planned broadcast occupies them.
    private var stashedTemplate: Fields?
    private var plannedLoaded: PlannedStreamDetails?
    private var plannedMembership: YouTubePlaylistMembership?
    private var plannedStartTime: String?
    private var savedThumbnailChanged = false

    var activeThumbnail: SettingsThumbnailDraft {
        plannedChoice == .newStream ? thumbnail : plannedThumbnail
    }

    private var currentFields: Fields {
        Fields(title: title, visibility: visibility, madeForKids: madeForKids, enableDvr: enableDvr,
               enableEmbed: enableEmbed, latencyPreference: latencyPreference, playlistId: playlistId)
    }

    private func set(_ fields: Fields) {
        title = fields.title
        visibility = fields.visibility
        madeForKids = fields.madeForKids
        enableDvr = fields.enableDvr
        enableEmbed = fields.enableEmbed
        latencyPreference = fields.latencyPreference
        playlistId = fields.playlistId
    }

    private func set(_ details: PlannedStreamDetails) {
        set(Fields(title: details.title, visibility: details.privacyStatus,
                   madeForKids: details.selfDeclaredMadeForKids, enableDvr: details.enableDvr,
                   enableEmbed: details.enableEmbed, latencyPreference: details.latencyPreference,
                   playlistId: details.playlistId))
    }

    private func details(from fields: Fields) -> PlannedStreamDetails {
        var details = PlannedStreamDetails(
            broadcast: broadcast ?? .draft(for: YouTubeStream(id: "", streamName: "", publishedAt: nil,
                                                              ingestionType: "", ingestionAddress: "",
                                                              backupIngestionAddress: nil)),
            playlistId: fields.playlistId)
        details.title = fields.title
        details.privacyStatus = fields.visibility
        details.selfDeclaredMadeForKids = fields.madeForKids
        details.enableDvr = fields.enableDvr
        details.enableEmbed = fields.enableEmbed
        details.latencyPreference = fields.latencyPreference
        return details
    }

    func applyPlanned(_ planned: YouTubePlannedStreams, saved: PlannedStreamSelection?, savedThumbnail: Data?,
                      now: Date, calendar: Calendar) {
        plannedBroadcasts = planned.broadcasts
        plannedNeedsOwnKey = planned.needsOwnKey
        if case .planned(let id) = plannedChoice, !planned.broadcasts.contains(where: { $0.id == id }) {
            choose(.newStream)
        }
        guard plannedChoice == .newStream, let saved else { return }
        let image = savedThumbnail.flatMap { UIImage(data: $0) }
        switch saved.kind {
        case .planned:
            // By broadcast only: Start follows the broadcast's current key.
            guard planned.broadcasts.contains(where: { $0.id == saved.broadcastId }) else { return }
            enter(.planned(saved.broadcastId), selection: saved, image: image)
        case .restart:
            guard PlannedStreams.isScheduledToday(saved.scheduledStartTime, now: now, calendar: calendar) else { return }
            restartSelection = saved
            enter(.restart, selection: saved, image: image)
        }
    }

    private func enter(_ choice: PlannedStreamChoice, selection: PlannedStreamSelection, image: UIImage?) {
        stashedTemplate = currentFields
        plannedChoice = choice
        set(selection.edited)
        plannedLoaded = selection.loaded
        plannedMembership = selection.loadedMembership
        plannedStartTime = selection.scheduledStartTime
        savedThumbnailChanged = selection.thumbnailChanged
        plannedThumbnail.reset(image: image)
    }

    func choose(_ choice: PlannedStreamChoice) {
        guard choice != plannedChoice else { return }
        if choice == .restart, restartSelection == nil { return }
        if plannedChoice == .newStream {
            stashedTemplate = currentFields
        }
        plannedChoice = choice
        plannedLoaded = nil
        plannedMembership = nil
        savedThumbnailChanged = false
        plannedThumbnail.reset()
        switch choice {
        case .newStream:
            if let stashedTemplate { set(stashedTemplate) }
            stashedTemplate = nil
            plannedStartTime = nil
        case .planned(let id):
            plannedStartTime = plannedBroadcasts.first { $0.id == id }?.scheduledStartTime
        case .restart:
            guard let restartSelection else { return }
            set(restartSelection.edited)
            plannedLoaded = restartSelection.loaded
            plannedStartTime = restartSelection.scheduledStartTime
            savedThumbnailChanged = restartSelection.thumbnailChanged
        }
    }

    func loadPlannedDetails(for broadcastId: String, membership: YouTubePlaylistMembership?, thumbnail: Data?) {
        guard plannedChoice == .planned(broadcastId),
              let planned = plannedBroadcasts.first(where: { $0.id == broadcastId }) else { return }
        let loaded = PlannedStreamDetails(broadcast: planned, playlistId: membership?.playlistId)
        set(loaded)
        plannedLoaded = loaded
        plannedMembership = membership
        plannedThumbnail.reset(image: thumbnail.flatMap { UIImage(data: $0) })
    }

    /// Nil for "New stream" and while a planned broadcast's details are still loading.
    func plannedSelection() -> PlannedStreamSelection? {
        let changed = plannedThumbnail.hasNewSelection || savedThumbnailChanged
        switch plannedChoice {
        case .newStream:
            return nil
        case .restart:
            guard var selection = restartSelection else { return nil }
            selection.edited = details(from: currentFields)
            selection.thumbnailChanged = changed
            return selection
        case .planned(let id):
            guard let loaded = plannedLoaded, let start = plannedStartTime else { return nil }
            let streamId = plannedBroadcasts.first(where: { $0.id == id })?.boundStreamId
            return PlannedStreamSelection(
                kind: .planned, broadcastId: id, streamId: streamId, scheduledStartTime: start,
                loaded: loaded, edited: details(from: currentFields),
                loadedMembership: plannedMembership, thumbnailChanged: changed)
        }
    }

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
        plannedBroadcasts = []
        restartSelection = nil
        plannedChoice = .newStream
        stashedTemplate = nil
        plannedLoaded = nil
        plannedMembership = nil
        plannedStartTime = nil
        savedThumbnailChanged = false
        plannedThumbnail.reset()
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
