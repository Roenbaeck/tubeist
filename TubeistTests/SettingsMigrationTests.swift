//
//  SettingsMigrationTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

private enum TestCredentialError: Error {
    case injectedFailure
}

private final class MemoryCredentialStore: CredentialStoring {
    var values: [TubeistCredential: String]
    var failOnceFor: TubeistCredential?

    init(values: [TubeistCredential: String] = [:]) {
        self.values = values
    }

    func value(for credential: TubeistCredential) throws -> String? {
        values[credential]
    }

    func setValue(_ value: String?, for credential: TubeistCredential) throws {
        if failOnceFor == credential {
            failOnceFor = nil
            throw TestCredentialError.injectedFailure
        }
        values[credential] = value
    }
}

struct SettingsMigrationTests {
    @Test func migratesOnlyYouTubeSecretsAndRemovesLegacySettings() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let store = MemoryCredentialStore()
        defaults.set(try JSONEncoder().encode([
            "youtube": "youtube-key",
            "twitch": "do-not-migrate",
        ]), forKey: "TargetData")
        defaults.set("access", forKey: "YouTubeAccessToken")
        defaults.set("refresh", forKey: "YouTubeRefreshToken")
        defaults.set("https://relay.invalid", forKey: "HLSServer")
        defaults.set("relay-user", forKey: "Username")
        defaults.set("relay-password", forKey: "Password")
        defaults.set("twitch", forKey: "Target")
        defaults.set("relay", forKey: "StreamDestination")

        let result = try LegacySettingsMigration.run(defaults: defaults, credentials: store)

        #expect(result.performed)
        #expect(!result.requiresYouTubeSetup)
        #expect(result.migratedCredentials == Set(TubeistCredential.allCases))
        #expect(store.values[.youTubeStreamKey] == "youtube-key")
        #expect(store.values[.youTubeAccessToken] == "access")
        #expect(store.values[.youTubeRefreshToken] == "refresh")
        #expect(!store.values.values.contains("do-not-migrate"))
        #expect(defaults.integer(forKey: LegacySettingsMigration.versionKey) == 1)
        #expect(defaults.object(forKey: "TargetData") == nil)
        #expect(defaults.object(forKey: "HLSServer") == nil)
        #expect(defaults.object(forKey: "Username") == nil)
        #expect(defaults.object(forKey: "Password") == nil)
        #expect(defaults.object(forKey: "Target") == nil)
        #expect(defaults.object(forKey: "StreamDestination") == nil)
        #expect(defaults.object(forKey: "YouTubeAccessToken") == nil)
        #expect(defaults.object(forKey: "YouTubeRefreshToken") == nil)
    }

    @Test func preservesExistingSecureValues() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let store = MemoryCredentialStore(values: [.youTubeStreamKey: "secure-key"])
        defaults.set(try JSONEncoder().encode(["youtube": "legacy-key"]), forKey: "TargetData")

        let result = try LegacySettingsMigration.run(defaults: defaults, credentials: store)

        #expect(result.performed)
        #expect(!result.migratedCredentials.contains(.youTubeStreamKey))
        #expect(store.values[.youTubeStreamKey] == "secure-key")
        #expect(!result.requiresYouTubeSetup)
        #expect(defaults.object(forKey: "TargetData") == nil)
    }

    @Test func retriesAfterAWriteFailureWithoutDeletingLegacyValues() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let store = MemoryCredentialStore()
        store.failOnceFor = .youTubeRefreshToken
        defaults.set(try JSONEncoder().encode(["youtube": "youtube-key"]), forKey: "TargetData")
        defaults.set("access", forKey: "YouTubeAccessToken")
        defaults.set("refresh", forKey: "YouTubeRefreshToken")

        #expect(throws: TestCredentialError.self) {
            try LegacySettingsMigration.run(defaults: defaults, credentials: store)
        }
        #expect(defaults.integer(forKey: LegacySettingsMigration.versionKey) == 0)
        #expect(defaults.object(forKey: "TargetData") != nil)
        #expect(defaults.string(forKey: "YouTubeRefreshToken") == "refresh")

        let retry = try LegacySettingsMigration.run(defaults: defaults, credentials: store)
        #expect(retry.performed)
        #expect(store.values[.youTubeStreamKey] == "youtube-key")
        #expect(store.values[.youTubeAccessToken] == "access")
        #expect(store.values[.youTubeRefreshToken] == "refresh")
        #expect(defaults.object(forKey: "TargetData") == nil)
    }

    @Test func completedMigrationIsIdempotent() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let store = MemoryCredentialStore()
        defaults.set(try JSONEncoder().encode(["youtube": "youtube-key"]), forKey: "TargetData")

        _ = try LegacySettingsMigration.run(defaults: defaults, credentials: store)
        defaults.set(try JSONEncoder().encode(["youtube": "later-legacy-key"]), forKey: "TargetData")
        let second = try LegacySettingsMigration.run(defaults: defaults, credentials: store)

        #expect(!second.performed)
        #expect(!second.requiresYouTubeSetup)
        #expect(second.migratedCredentials.isEmpty)
        #expect(store.values[.youTubeStreamKey] == "youtube-key")
    }

    @Test func disablesLegacyStreamingWhenThereIsNoYouTubeKey() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let store = MemoryCredentialStore()
        defaults.set(true, forKey: "Stream")
        defaults.set(
            try JSONEncoder().encode(["twitch": "legacy-twitch-key"]),
            forKey: "TargetData"
        )

        let result = try LegacySettingsMigration.run(defaults: defaults, credentials: store)

        #expect(result.performed)
        #expect(result.requiresYouTubeSetup)
        #expect(!defaults.bool(forKey: "Stream"))
        #expect(store.values[.youTubeStreamKey] == nil)
    }
}

/// These touch the real `UserDefaults.standard` keys and Application Support
/// files through `Settings`, so they run serialized and restore what they found.
@Suite(.serialized)
struct PlannedSelectionPersistenceTests {
    private struct Saved {
        let selection: PlannedStreamSelection?
        let plannedThumbnail: Data?
        let preferences: YouTubeBroadcastPreferences?
        let templateThumbnail: Data?

        @MainActor
        static func capture() throws -> Saved {
            Saved(
                selection: Settings.plannedStreamSelection,
                plannedThumbnail: try Settings.loadPlannedStreamThumbnailData(),
                preferences: Settings.youtubeBroadcastPreferences,
                templateThumbnail: try Settings.loadYouTubeThumbnailData()
            )
        }

        @MainActor
        func restore() throws {
            Settings.plannedStreamSelection = selection
            try Settings.setPlannedStreamThumbnailData(plannedThumbnail)
            Settings.youtubeBroadcastPreferences = preferences
            try Settings.setYouTubeThumbnailData(templateThumbnail)
        }
    }

    private func preferences() -> YouTubeBroadcastPreferences {
        YouTubeBroadcastPreferences(
            streamId: "stream-1", title: "Template", privacyStatus: "unlisted",
            enableDvr: true, latencyPreference: "low", enableMonitorStream: false,
            broadcastStreamDelayMs: 0, enableEmbed: false, recordFromStart: true,
            enableAutoStart: true, enableAutoStop: true, playlistId: "pl-1"
        )
    }

    private func selection() -> PlannedStreamSelection {
        let details = PlannedStreamDetails(
            broadcast: YouTubeBroadcast(
                id: "b-1", title: "Match 5", privacyStatus: "unlisted", boundStreamId: "stream-1",
                scheduledStartTime: "2026-10-31T09:00:00Z", actualStartTime: nil, publishedAt: nil,
                lifeCycleStatus: "ready", enableDvr: true, latencyPreference: "low",
                enableMonitorStream: false, broadcastStreamDelayMs: 0, enableEmbed: false,
                recordFromStart: true, enableAutoStart: true, enableAutoStop: true,
                selfDeclaredMadeForKids: false
            ),
            playlistId: "pl-1"
        )
        return PlannedStreamSelection(
            kind: .planned, broadcastId: "b-1", streamId: "stream-1",
            scheduledStartTime: "2026-10-31T09:00:00Z", loaded: details, edited: details,
            loadedMembership: YouTubePlaylistMembership(playlistId: "pl-1", itemId: "item-1"),
            thumbnailChanged: true
        )
    }

    @Test @MainActor func existingSettingsWithoutAPlannedSelectionLoadUnchanged() throws {
        let saved = try Saved.capture()
        defer { try? saved.restore() }
        let template = preferences()
        let thumbnail = Data([0xFF, 0xD8, 0x01, 0x02])
        UserDefaults.standard.removeObject(forKey: "PlannedStreamSelection")
        try Settings.setPlannedStreamThumbnailData(nil)
        Settings.youtubeBroadcastPreferences = template
        try Settings.setYouTubeThumbnailData(thumbnail)

        #expect(Settings.plannedStreamSelection == nil)
        #expect(try Settings.loadPlannedStreamThumbnailData() == nil)
        #expect(Settings.youtubeBroadcastPreferences == template)
        #expect(try Settings.loadYouTubeThumbnailData() == thumbnail)
    }

    @Test @MainActor func plannedSelectionAndThumbnailRoundTripAndClear() throws {
        let saved = try Saved.capture()
        defer { try? saved.restore() }
        let expected = selection()
        let thumbnail = Data([0xFF, 0xD8, 0x09])

        Settings.plannedStreamSelection = expected
        try Settings.setPlannedStreamThumbnailData(thumbnail)
        #expect(Settings.plannedStreamSelection == expected)
        #expect(try Settings.loadPlannedStreamThumbnailData() == thumbnail)

        Settings.plannedStreamSelection = nil
        try Settings.setPlannedStreamThumbnailData(nil)
        #expect(UserDefaults.standard.object(forKey: "PlannedStreamSelection") == nil)
        #expect(try Settings.loadPlannedStreamThumbnailData() == nil)
    }
}
