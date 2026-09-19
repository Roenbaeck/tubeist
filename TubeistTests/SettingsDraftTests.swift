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
