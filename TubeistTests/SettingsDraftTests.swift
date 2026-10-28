import Foundation
import Testing
import UIKit
@testable import Tubeist

@MainActor
struct SettingsDraftTests {
    @Test func presetDerivesLadderAndReloadsLegacySettingsWithoutPersistingDerivedValues() throws {
        let preset = Preset(name: "Custom", width: 1920, height: 1080, frameRate: 30, keyframeInterval: 2,
                            audioChannels: 2, audioBitrate: 96_000, videoBitrate: 6_000_000)
        #expect(preset.bitrateLadder.maximum == 6_000_000)
        #expect(preset.bitrateLadder.minimum == 933_120)
        let data = try JSONEncoder().encode(preset)
        #expect(!String(decoding: data, as: UTF8.self).contains("ladder"))
        #expect(try JSONDecoder().decode(Preset.self, from: data).bitrateLadder == preset.bitrateLadder)
        let low = Preset(name: "Custom", width: 3840, height: 2160, frameRate: 60, keyframeInterval: 2,
                         audioChannels: 2, audioBitrate: 128_000, videoBitrate: 100_000)
        #expect(low.bitrateLadder.rungs == [100_000])
    }

    @Test func switchingCameraModesKeepsResolutionAndUsesTheNewBitrateAndKeyframeInterval() throws {
        for stationary in stationaryCameraPresets {
            let moving = Preset.forCameraPosition("moving", matching: stationary)
            #expect(moving.width == stationary.width)
            #expect(moving.height == stationary.height)
            #expect(moving.videoBitrate > stationary.videoBitrate)
            #expect(moving.keyframeInterval == 1)
            #expect(Preset.forCameraPosition("stationary", matching: moving) == stationary)
            let saved = try JSONEncoder().encode(moving)
            #expect(try JSONDecoder().decode(Preset.self, from: saved) == moving)
        }
    }

    @Test func leavingCustomUsesAValidPresetAtTheSameResolution() {
        let custom = Preset(name: "Custom", width: 3840, height: 2160, frameRate: 60,
                            keyframeInterval: 0.5, audioChannels: 1, audioBitrate: 64_000,
                            videoBitrate: 20_000_000)
        let preset = Preset.forCameraPosition("moving", matching: custom)
        #expect(preset == movingCameraPresets.last)
    }

    @Test func refreshUpdatesStatusButPreservesEveryEditableFieldAndThumbnail() async throws {
        let draft = YouTubeSettingsDraft()
        draft.useStreamKey("key-a")
        var broadcast = makeBroadcast()
        let playlists = [YouTubePlaylist(id: "playlist-a", title: "Matches")]
        draft.apply(broadcast: broadcast, playlists: playlists, savedPreferences: nil, savedThumbnail: nil)
        draft.title = "Unsaved title"
        draft.visibility = "unlisted"
        draft.enableDvr = false
        draft.enableEmbed = true
        draft.madeForKids = true
        draft.latencyPreference = "low"
        draft.playlistId = "playlist-a"
        let data = try imageData(.red)
        await draft.thumbnail.select { data }.value
        let image = draft.thumbnail.image

        // Hiding and showing streaming settings keeps the same draft identity.
        draft.useStreamKey("key-a")
        broadcast.lifeCycleStatus = "live"
        broadcast.title = "Remote title"
        draft.apply(broadcast: broadcast, playlists: playlists, savedPreferences: nil, savedThumbnail: nil)

        #expect(draft.broadcast?.lifeCycleStatus == "live")
        #expect(draft.title == "Unsaved title")
        #expect(draft.visibility == "unlisted")
        #expect(!draft.enableDvr)
        #expect(draft.enableEmbed)
        #expect(draft.madeForKids)
        #expect(draft.latencyPreference == "low")
        #expect(draft.playlistId == "playlist-a")
        #expect(draft.thumbnail.image === image)
        #expect(draft.thumbnail.hasNewSelection)
    }

    @Test func refreshedBroadcastOnAnotherStreamDoesNotInheritEdits() {
        let draft = YouTubeSettingsDraft()
        draft.apply(broadcast: makeBroadcast(), playlists: [], savedPreferences: nil, savedThumbnail: nil)
        draft.title = "Only for the first stream"
        let other = makeBroadcast(streamID: "stream-b")
        draft.apply(broadcast: other, playlists: [], savedPreferences: nil, savedThumbnail: nil)
        #expect(draft.title == other.title)
    }

    @Test func refreshDoesNotCancelAnInProgressThumbnailSelection() async throws {
        let draft = YouTubeSettingsDraft()
        let broadcast = makeBroadcast()
        draft.apply(broadcast: broadcast, playlists: [], savedPreferences: nil, savedThumbnail: nil)
        let probe = ThumbnailLoadProbe()
        let data = try imageData(.red)
        let pending = draft.thumbnail.select { await probe.pause(); return data }
        await probe.waitUntilRequested()
        draft.apply(broadcast: broadcast, playlists: [], savedPreferences: nil, savedThumbnail: nil)
        #expect(draft.thumbnail.isLoading)
        probe.resume()
        await pending.value
        #expect(draft.thumbnail.image != nil)
        #expect(draft.thumbnail.hasNewSelection)
    }

    @Test func refreshClearsADeletedPlaylistSelection() {
        let draft = YouTubeSettingsDraft()
        let broadcast = makeBroadcast()
        draft.apply(broadcast: broadcast, playlists: [.init(id: "p", title: "Playlist")],
                    savedPreferences: nil, savedThumbnail: nil)
        draft.playlistId = "p"
        draft.apply(broadcast: broadcast, playlists: [], savedPreferences: nil, savedThumbnail: nil)
        #expect(draft.playlistId == nil)
    }

    @Test func firstLoadUsesPreferencesAndThumbnailOnlyForTheMatchingStream() throws {
        let draft = YouTubeSettingsDraft()
        let broadcast = makeBroadcast()
        let preferences = YouTubeBroadcastPreferences(
            streamId: "stream-a", title: "Saved title", privacyStatus: "unlisted", enableDvr: false,
            latencyPreference: "low", enableMonitorStream: false, broadcastStreamDelayMs: 0,
            enableEmbed: false, recordFromStart: true, enableAutoStart: true, enableAutoStop: true,
            playlistId: nil, selfDeclaredMadeForKids: true
        )
        let data = try imageData(.red)
        draft.apply(broadcast: broadcast, playlists: [], savedPreferences: preferences, savedThumbnail: data)
        #expect(draft.title == "Saved title")
        #expect(draft.visibility == "unlisted")
        #expect(draft.madeForKids)
        #expect(draft.thumbnail.image != nil)
        #expect(!draft.thumbnail.hasNewSelection)

        let other = makeBroadcast(streamID: "stream-b")
        draft.apply(broadcast: other, playlists: [], savedPreferences: preferences, savedThumbnail: data)
        #expect(draft.title == other.title)
        #expect(draft.thumbnail.image == nil)
    }

    @Test func embeddingShowsTheLoadedBroadcastAndRoundTripsThroughSavedPreferences() throws {
        // App-created drafts keep embedding off; a Studio event shows its own value.
        let appDraft = YouTubeSettingsDraft()
        appDraft.apply(broadcast: makeBroadcast(), playlists: [], savedPreferences: nil, savedThumbnail: nil)
        #expect(!appDraft.enableEmbed)
        var studioEvent = makeBroadcast()
        studioEvent.enableEmbed = true
        studioEvent.recordFromStart = false
        let draft = YouTubeSettingsDraft()
        draft.apply(broadcast: studioEvent, playlists: [], savedPreferences: nil, savedThumbnail: nil)
        #expect(draft.enableEmbed)

        draft.enableEmbed = false
        let saved = try #require(draft.preferences())
        #expect(saved.streamId == "stream-a")
        #expect(!saved.enableEmbed)
        #expect(!saved.recordFromStart)
        #expect(saved.enableAutoStop)
        let stored = try JSONDecoder().decode(YouTubeBroadcastPreferences.self, from: JSONEncoder().encode(saved))
        #expect(stored == saved)
        #expect(!stored.applying(to: studioEvent).enableEmbed)

        let reopened = YouTubeSettingsDraft()
        reopened.apply(broadcast: studioEvent, playlists: [], savedPreferences: stored, savedThumbnail: nil)
        #expect(!reopened.enableEmbed)
        reopened.enableEmbed = true
        #expect(try #require(reopened.preferences()).applying(to: makeBroadcast()).enableEmbed)
        reopened.reset()
        #expect(!reopened.enableEmbed)
        #expect(reopened.preferences() == nil)
    }

    @Test func aSlowOlderThumbnailCannotReplaceTheLatestSelection() async throws {
        let thumbnail = SettingsThumbnailDraft()
        let probe = ThumbnailLoadProbe()
        let red = try imageData(.red)
        let blue = try imageData(.blue)
        let first = thumbnail.select { await probe.pause(); return red }
        await probe.waitUntilRequested()
        #expect(thumbnail.isLoading)
        #expect(!thumbnail.hasNewSelection)
        await thumbnail.select { blue }.value
        let latest = thumbnail.image
        #expect(latest != nil)
        #expect(!thumbnail.isLoading)
        probe.resume()
        await first.value
        #expect(thumbnail.image === latest)
        #expect(thumbnail.hasNewSelection)
        #expect(thumbnail.errorMessage == nil)
    }

    @Test func anOlderFailureCannotFinishANewerThumbnailLoad() async throws {
        let thumbnail = SettingsThumbnailDraft()
        let oldProbe = ThumbnailLoadProbe()
        let newProbe = ThumbnailLoadProbe()
        let data = try imageData(.blue)
        let first = thumbnail.select { await oldProbe.pause(); throw CocoaError(.fileReadUnknown) }
        await oldProbe.waitUntilRequested()
        let second = thumbnail.select { await newProbe.pause(); return data }
        await newProbe.waitUntilRequested()
        oldProbe.resume()
        await first.value
        #expect(thumbnail.isLoading)
        #expect(thumbnail.errorMessage == nil)
        newProbe.resume()
        await second.value
        #expect(!thumbnail.isLoading)
        #expect(thumbnail.image != nil)
    }

    @Test func invalidThumbnailKeepsPreviousSelectionAndAllowsRetry() async throws {
        let thumbnail = SettingsThumbnailDraft()
        let data = try imageData(.red)
        await thumbnail.select { data }.value
        let previous = thumbnail.image
        await thumbnail.select { Data("invalid image".utf8) }.value
        #expect(thumbnail.image === previous)
        #expect(thumbnail.hasNewSelection)
        #expect(!thumbnail.isLoading)
        #expect(thumbnail.errorMessage != nil)
        await thumbnail.select { data }.value
        #expect(thumbnail.errorMessage == nil)
    }

    @Test func switchingKeysOrSigningOutInvalidatesPendingThumbnailLoads() async throws {
        for signOut in [false, true] {
            let draft = YouTubeSettingsDraft()
            draft.useStreamKey("key-a")
            draft.apply(broadcast: makeBroadcast(), playlists: [], savedPreferences: nil, savedThumbnail: nil)
            draft.title = "Account A draft"
            let probe = ThumbnailLoadProbe()
            let data = try imageData(.red)
            let pending = draft.thumbnail.select { await probe.pause(); return data }
            await probe.waitUntilRequested()
            if signOut { draft.reset() } else { draft.useStreamKey("key-b") }
            probe.resume()
            await pending.value
            #expect(draft.broadcast == nil)
            #expect(draft.title.isEmpty)
            #expect(draft.thumbnail.image == nil)
            #expect(!draft.thumbnail.isLoading)
            #expect(!draft.thumbnail.hasNewSelection)
        }
    }

    // MARK: Planned streams

    private static let now = ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z")!
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func plannedBroadcast(_ id: String, title: String = "Planned", streamID: String = "stream-a",
                                  start: String = "2026-10-28T18:00:00Z") -> YouTubeBroadcast {
        YouTubeBroadcast(
            id: id, title: title, privacyStatus: "unlisted",
            boundStreamId: streamID, scheduledStartTime: start, actualStartTime: nil,
            publishedAt: nil, lifeCycleStatus: "ready", enableDvr: false,
            latencyPreference: "low", enableMonitorStream: false,
            broadcastStreamDelayMs: 0, enableEmbed: true, recordFromStart: true,
            enableAutoStart: true, enableAutoStop: true, selfDeclaredMadeForKids: true
        )
    }

    private func plannedDraft(saved: PlannedStreamSelection? = nil,
                              broadcasts: [YouTubeBroadcast]? = nil) -> YouTubeSettingsDraft {
        let draft = YouTubeSettingsDraft()
        draft.useStreamKey("key-a")
        draft.apply(broadcast: makeBroadcast(), playlists: [YouTubePlaylist(id: "pl", title: "Matches")],
                    savedPreferences: nil, savedThumbnail: nil)
        draft.title = "Template title"
        draft.visibility = "private"
        draft.enableDvr = true
        draft.enableEmbed = false
        draft.madeForKids = false
        draft.latencyPreference = "normal"
        draft.playlistId = "pl"
        draft.applyPlanned(
            YouTubePlannedStreams(streamTitle: "Phone", broadcasts: broadcasts ?? [plannedBroadcast("b1")]),
            saved: saved, savedThumbnail: nil, now: Self.now, calendar: Self.utc)
        return draft
    }

    private func savedSelection(kind: PlannedStreamSelection.Kind = .planned, broadcastId: String = "b1",
                                streamId: String = "stream-a",
                                start: String = "2026-10-28T18:00:00Z") -> PlannedStreamSelection {
        let loaded = PlannedStreamDetails(broadcast: plannedBroadcast(broadcastId), playlistId: nil)
        var edited = loaded
        edited.title = "Edited"
        return PlannedStreamSelection(kind: kind, broadcastId: broadcastId, streamId: streamId,
                                      scheduledStartTime: start, loaded: loaded, edited: edited,
                                      loadedMembership: nil, thumbnailChanged: false)
    }

    @Test func choosingAPlannedMatchThenNewStreamRestoresTheTemplateExactly() {
        let draft = plannedDraft()
        let before = draft.preferences()
        draft.choose(.planned("b1"))
        draft.loadPlannedDetails(for: "b1", membership: YouTubePlaylistMembership(playlistId: "other", itemId: "i"),
                                 thumbnail: nil)
        #expect(draft.title == "Planned")
        #expect(draft.visibility == "unlisted")
        #expect(draft.madeForKids)
        #expect(draft.playlistId == "other")
        draft.choose(.newStream)
        #expect(draft.preferences() == before)
        #expect(draft.playlistId == "pl")
        #expect(draft.latencyPreference == "normal")
        #expect(draft.plannedSelection() == nil)
    }

    @Test func plannedEditsDoNotChangeTemplatePreferences() {
        let draft = plannedDraft()
        let before = draft.preferences()
        draft.choose(.planned("b1"))
        draft.loadPlannedDetails(for: "b1", membership: nil, thumbnail: nil)
        draft.title = "Edited planned"
        draft.choose(.newStream)
        #expect(draft.preferences() == before)
    }

    @Test func plannedSelectionRecordsLoadedAndEditedSeparately() {
        let draft = plannedDraft()
        let membership = YouTubePlaylistMembership(playlistId: "pl", itemId: "item")
        draft.choose(.planned("b1"))
        draft.loadPlannedDetails(for: "b1", membership: membership, thumbnail: nil)
        draft.title = "Edited"
        let selection = draft.plannedSelection()
        #expect(selection?.kind == .planned)
        #expect(selection?.broadcastId == "b1")
        #expect(selection?.streamId == "stream-a")
        #expect(selection?.loaded.title == "Planned")
        #expect(selection?.loaded.playlistId == "pl")
        #expect(selection?.edited.title == "Edited")
        #expect(selection?.loadedMembership == membership)
        #expect(selection?.thumbnailChanged == false)
    }

    @Test func lateDetailsForAPreviousChoiceAreIgnored() {
        let draft = plannedDraft(broadcasts: [plannedBroadcast("b1"), plannedBroadcast("b2", title: "Second")])
        draft.choose(.planned("b1"))
        draft.choose(.planned("b2"))
        draft.loadPlannedDetails(for: "b1", membership: nil, thumbnail: nil)
        #expect(draft.title != "Planned")
        draft.choose(.newStream)
        draft.loadPlannedDetails(for: "b2", membership: nil, thumbnail: nil)
        #expect(draft.title == "Template title")
    }

    @Test func savedChoiceIsRestoredOnlyIfStillInTodaysList() {
        let restored = plannedDraft(saved: savedSelection())
        #expect(restored.plannedChoice == .planned("b1"))
        #expect(restored.title == "Edited")
        #expect(restored.plannedSelection()?.loaded.title == "Planned")

        let missing = plannedDraft(saved: savedSelection(broadcastId: "gone"))
        #expect(missing.plannedChoice == .newStream)
        #expect(missing.title == "Template title")

        let otherStream = plannedDraft(saved: savedSelection(streamId: "stream-z"))
        #expect(otherStream.plannedChoice == .newStream)
    }

    @Test func savedRestartFromYesterdayIsNotOffered() {
        let old = plannedDraft(saved: savedSelection(kind: .restart, broadcastId: "ended",
                                                     start: "2026-10-27T18:00:00Z"))
        #expect(old.plannedChoice == .newStream)
        #expect(old.restartSelection == nil)

        let today = plannedDraft(saved: savedSelection(kind: .restart, broadcastId: "ended"))
        #expect(today.plannedChoice == .restart)
        #expect(today.restartSelection?.broadcastId == "ended")
        #expect(today.title == "Edited")
    }

    @Test func changingTheStreamKeyDropsThePlannedChoice() {
        let draft = plannedDraft(saved: savedSelection())
        #expect(draft.plannedChoice == .planned("b1"))
        draft.useStreamKey("key-b")
        #expect(draft.plannedChoice == .newStream)
        #expect(draft.plannedBroadcasts.isEmpty)
        #expect(draft.restartSelection == nil)
        #expect(draft.plannedSelection() == nil)
    }

    private func makeBroadcast(streamID: String = "stream-a") -> YouTubeBroadcast {
        .draft(for: YouTubeStream(id: streamID, streamName: "key", publishedAt: nil,
                                 ingestionType: "hls", ingestionAddress: "https://example.invalid/",
                                 backupIngestionAddress: nil))
    }

    private func imageData(_ color: UIColor) throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return try #require(image.pngData())
    }
}

@MainActor
private final class ThumbnailLoadProbe {
    private var reply: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            reply = continuation
            waiter?.resume()
            waiter = nil
        }
    }

    func waitUntilRequested() async {
        if reply != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func resume() {
        reply?.resume()
        reply = nil
    }
}
