//
//  CredentialStore.swift
//  Tubeist
//

import Foundation
import Security

enum TubeistCredential: String, CaseIterable, Hashable, Sendable {
    case youTubeStreamKey = "youtube-stream-key"
    case youTubeAccessToken = "youtube-access-token"
    case youTubeRefreshToken = "youtube-refresh-token"
}

enum CredentialStoreError: Error, Equatable {
    case invalidStoredValue(TubeistCredential)
    case keychain(OSStatus)
}

protocol CredentialStoring {
    func value(for credential: TubeistCredential) throws -> String?
    func setValue(_ value: String?, for credential: TubeistCredential) throws
}

struct KeychainCredentialStore: CredentialStoring, Sendable {
    private let service: String
#if DEBUG
    private static let uiTestingStorage = UITestingCredentialStorage()
#endif

    init(service: String = Bundle.main.bundleIdentifier ?? "com.subside.Tubeist") {
        self.service = service
    }

    func value(for credential: TubeistCredential) throws -> String? {
#if DEBUG
        if CommandLine.arguments.contains("-ui-testing") {
            return Self.uiTestingStorage.value(for: credential)
        }
#endif
        var query = baseQuery(for: credential)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychain(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.invalidStoredValue(credential)
        }
        return value
    }

    func setValue(_ value: String?, for credential: TubeistCredential) throws {
#if DEBUG
        if CommandLine.arguments.contains("-ui-testing") {
            Self.uiTestingStorage.setValue(value, for: credential)
            return
        }
#endif
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(baseQuery(for: credential) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialStoreError.keychain(status)
            }
            return
        }

        let encoded = Data(value.utf8)
        let query = baseQuery(for: credential)
        let update: [String: Any] = [
            kSecValueData as String: encoded,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychain(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = encoded
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(addStatus)
        }
    }

    private func baseQuery(for credential: TubeistCredential) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.rawValue,
        ]
    }
}

#if DEBUG
private final class UITestingCredentialStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TubeistCredential: String] = [:]

    func value(for credential: TubeistCredential) -> String? {
        lock.withLock { values[credential] }
    }

    func setValue(_ value: String?, for credential: TubeistCredential) {
        lock.withLock { values[credential] = value }
    }
}
#endif

struct LegacySettingsMigrationResult: Equatable {
    let performed: Bool
    let migratedCredentials: Set<TubeistCredential>
    let requiresYouTubeSetup: Bool
}

enum LegacySettingsMigration {
    static let versionKey = "SettingsSchemaVersion"
    static let currentVersion = 1

    private static let obsoleteKeys = [
        "HLSServer",
        "Username",
        "Password",
        "Target",
        "StreamDestination",
        "TargetData",
        "YouTubeAccessToken",
        "YouTubeRefreshToken",
    ]

    static func run(
        defaults: UserDefaults = .standard,
        credentials: any CredentialStoring = KeychainCredentialStore()
    ) throws -> LegacySettingsMigrationResult {
        guard defaults.integer(forKey: versionKey) < currentVersion else {
            return LegacySettingsMigrationResult(
                performed: false,
                migratedCredentials: [],
                requiresYouTubeSetup: false
            )
        }

        var migrated: Set<TubeistCredential> = []
        let legacyTargetValues: [String: String]
        if let data = defaults.data(forKey: "TargetData"),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            legacyTargetValues = decoded
        } else {
            legacyTargetValues = [:]
        }

        try migrate(
            legacyTargetValues["youtube"],
            to: .youTubeStreamKey,
            credentials: credentials,
            migrated: &migrated
        )
        try migrate(
            defaults.string(forKey: "YouTubeAccessToken"),
            to: .youTubeAccessToken,
            credentials: credentials,
            migrated: &migrated
        )
        try migrate(
            defaults.string(forKey: "YouTubeRefreshToken"),
            to: .youTubeRefreshToken,
            credentials: credentials,
            migrated: &migrated
        )

        let requiresYouTubeSetup = try credentials.value(for: .youTubeStreamKey) == nil
        if requiresYouTubeSetup {
            defaults.set(false, forKey: "Stream")
        }

        for key in obsoleteKeys {
            defaults.removeObject(forKey: key)
        }
        defaults.set(currentVersion, forKey: versionKey)

        return LegacySettingsMigrationResult(
            performed: true,
            migratedCredentials: migrated,
            requiresYouTubeSetup: requiresYouTubeSetup
        )
    }

    private static func migrate(
        _ legacyValue: String?,
        to credential: TubeistCredential,
        credentials: any CredentialStoring,
        migrated: inout Set<TubeistCredential>
    ) throws {
        guard try credentials.value(for: credential) == nil,
              let legacyValue,
              !legacyValue.isEmpty else {
            return
        }
        try credentials.setValue(legacyValue, for: credential)
        migrated.insert(credential)
    }
}
