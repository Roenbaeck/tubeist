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
