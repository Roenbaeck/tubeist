//
//  YouTubeService.swift
//  Tubeist
//
//  YouTube Data API v3 integration for managing stream settings.
//  Handles OAuth2 authentication and broadcast/playlist management.
//

import Foundation
import Observation
import AuthenticationServices
import CryptoKit
import Security
import UIKit

// MARK: - Models

struct YouTubeBroadcast: Identifiable, Sendable, Equatable {
    let id: String
    var title: String
    var privacyStatus: String
    let boundStreamId: String?
    let scheduledStartTime: String?
    let actualStartTime: String?
    let publishedAt: String?
    var lifeCycleStatus: String?
    var enableDvr: Bool
    var latencyPreference: String
    var enableMonitorStream: Bool
    var broadcastStreamDelayMs: Int
    var enableEmbed: Bool
    var recordFromStart: Bool
    var enableAutoStart: Bool
    var enableAutoStop: Bool

    var selfDeclaredMadeForKids: Bool? = nil

    /// A local template, never a remote broadcast ID or a status-polling target.
    static func draft(for stream: YouTubeStream) -> YouTubeBroadcast {
        YouTubeBroadcast(
            id: "", title: "Tubeist live stream", privacyStatus: "private",
            boundStreamId: stream.id, scheduledStartTime: nil, actualStartTime: nil,
            publishedAt: nil, lifeCycleStatus: "draft", enableDvr: true,
            latencyPreference: "normal", enableMonitorStream: false,
            broadcastStreamDelayMs: 0, enableEmbed: false, recordFromStart: true,
            enableAutoStart: true, enableAutoStop: true, selfDeclaredMadeForKids: false
        )
    }

    var isLive: Bool { lifeCycleStatus == "live" }
    var isTesting: Bool { lifeCycleStatus == "testing" }
    var isStarting: Bool {
        lifeCycleStatus == "liveStarting" || lifeCycleStatus == "testStarting"
    }
    var isActive: Bool { isLive || isTesting || isStarting }

    var statusLabel: String {
        Self.label(for: lifeCycleStatus)
    }

    static func label(for status: String?) -> String {
        switch status {
        case "draft": return "Created when you start"
        case "ready": return "Ready"
        case "testing": return "Testing"
        case "testStarting": return "Starting test"
        case "live": return "Live"
        case "liveStarting": return "Starting live stream"
        case "complete": return "Complete"
        case "revoked": return "Revoked"
        case "created": return "Created"
        default: return status ?? "Unknown"
        }
    }

    var statusColor: String {
        switch lifeCycleStatus {
        case "live": return "red"
        case "liveStarting": return "red"
        case "testing": return "orange"
        case "testStarting": return "orange"
        case "ready": return "green"
        case "complete": return "gray"
        default: return "secondary"
        }
    }
}

struct YouTubePlaylist: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
}

struct YouTubeStream: Sendable, Equatable {
    let id: String
    let streamName: String
    let publishedAt: String?
    let ingestionType: String
    let ingestionAddress: String
    let backupIngestionAddress: String?
}

struct YouTubeStreamingPreparation: Sendable, Equatable {
    let endpoint: YouTubeHLSEndpoint
    let broadcast: YouTubeBroadcast
}

/// Tubeist's saved template for the next broadcast on a particular reusable
/// YouTube stream. Saving this value is local-only; YouTube is mutated only as
/// part of the explicit Start preflight.
struct YouTubeBroadcastPreferences: Codable, Sendable, Equatable {
    let streamId: String
    var title: String
    var privacyStatus: String
    var enableDvr: Bool
    var latencyPreference: String
    var enableMonitorStream: Bool
    var broadcastStreamDelayMs: Int
    var enableEmbed: Bool
    var recordFromStart: Bool
    var enableAutoStart: Bool
    var enableAutoStop: Bool
    var playlistId: String?
    var selfDeclaredMadeForKids: Bool? = nil

    func applying(to broadcast: YouTubeBroadcast) -> YouTubeBroadcast {
        var updated = broadcast
        updated.title = title
        updated.privacyStatus = privacyStatus
        updated.enableDvr = enableDvr
        updated.latencyPreference = latencyPreference
        updated.enableMonitorStream = enableMonitorStream
        updated.broadcastStreamDelayMs = broadcastStreamDelayMs
        updated.enableEmbed = enableEmbed
        updated.recordFromStart = recordFromStart
        updated.enableAutoStart = enableAutoStart
        updated.enableAutoStop = enableAutoStop
        updated.selfDeclaredMadeForKids = selfDeclaredMadeForKids ?? broadcast.selfDeclaredMadeForKids
        return updated
    }
}

struct YouTubeListResponse<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
    let nextPageToken: String?
}

struct YouTubeChannelResource: Decodable, Sendable {
    struct Snippet: Decodable, Sendable { let title: String? }
    let id: String?
    let snippet: Snippet?
}

struct YouTubeLiveStreamResource: Decodable, Sendable {
    struct CDN: Decodable, Sendable {
        struct IngestionInfo: Decodable, Sendable {
            let streamName: String?
            let ingestionAddress: String?
            let backupIngestionAddress: String?
        }

        let ingestionType: String?
        let ingestionInfo: IngestionInfo?
    }

    struct Snippet: Decodable, Sendable {
        let publishedAt: String?
    }

    let id: String?
    let snippet: Snippet?
    let cdn: CDN?
}

struct YouTubeBroadcastResource: Decodable, Sendable {
    struct Snippet: Decodable, Sendable {
        let title: String?
        let scheduledStartTime: String?
        let actualStartTime: String?
        let publishedAt: String?
    }

    struct Status: Decodable, Sendable {
        let privacyStatus: String?
        let lifeCycleStatus: String?
        let selfDeclaredMadeForKids: Bool?
    }

    struct ContentDetails: Decodable, Sendable {
        struct MonitorStream: Decodable, Sendable {
            let enableMonitorStream: Bool?
            let broadcastStreamDelayMs: Int?
        }

        let boundStreamId: String?
        let enableDvr: Bool?
        let latencyPreference: String?
        let enableLowLatency: Bool?
        let monitorStream: MonitorStream?
        let enableEmbed: Bool?
        let recordFromStart: Bool?
        let enableAutoStart: Bool?
        let enableAutoStop: Bool?
    }

    let id: String?
    let snippet: Snippet?
    let status: Status?
    let contentDetails: ContentDetails?

    var broadcast: YouTubeBroadcast? {
        guard let id, let snippet else {
            return nil
        }
        let latencyPreference: String = {
            if let preference = contentDetails?.latencyPreference,
               ["normal", "low", "ultraLow"].contains(preference) {
                return preference
            }
            if contentDetails?.enableLowLatency == true {
                return "low"
            }
            return "normal"
        }()
        return YouTubeBroadcast(
            id: id,
            title: snippet.title ?? "",
            privacyStatus: status?.privacyStatus ?? "public",
            boundStreamId: contentDetails?.boundStreamId,
            scheduledStartTime: snippet.scheduledStartTime,
            actualStartTime: snippet.actualStartTime,
            publishedAt: snippet.publishedAt,
            lifeCycleStatus: status?.lifeCycleStatus,
            enableDvr: contentDetails?.enableDvr ?? true,
            latencyPreference: latencyPreference,
            enableMonitorStream: contentDetails?.monitorStream?.enableMonitorStream ?? false,
            broadcastStreamDelayMs: contentDetails?.monitorStream?.broadcastStreamDelayMs ?? 0,
            enableEmbed: contentDetails?.enableEmbed ?? true,
            recordFromStart: contentDetails?.recordFromStart ?? true,
            enableAutoStart: contentDetails?.enableAutoStart ?? true,
            enableAutoStop: contentDetails?.enableAutoStop ?? true,
            selfDeclaredMadeForKids: status?.selfDeclaredMadeForKids
        )
    }
}

struct YouTubePlaylistResource: Decodable, Sendable {
    struct Snippet: Decodable, Sendable {
        let title: String?
    }

    let id: String?
    let snippet: Snippet?
}

struct YouTubeIdentifierResource: Decodable, Sendable {
    let id: String?
}

struct YouTubeTokenResponse: Decodable, Sendable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let error: String?
    let errorDescription: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case error
        case errorDescription = "error_description"
        case scope
    }
}

protocol YouTubeTokenStoring {
    var accessToken: String? { get }
    var refreshToken: String? { get }
    var expiry: Date? { get set }

    func setAccessToken(_ value: String?) throws
    func setRefreshToken(_ value: String?) throws
    func clearAuthorization() throws
}

struct SettingsYouTubeTokenStore: YouTubeTokenStoring {
    var accessToken: String? { Settings.youtubeAccessToken }
    var refreshToken: String? { Settings.youtubeRefreshToken }
    var expiry: Date? {
        get { Settings.youtubeTokenExpiry }
        nonmutating set { Settings.youtubeTokenExpiry = newValue }
    }

    func setAccessToken(_ value: String?) throws {
        try Settings.setYouTubeAccessToken(value)
    }

    func setRefreshToken(_ value: String?) throws {
        try Settings.setYouTubeRefreshToken(value)
    }

    func clearAuthorization() throws {
        try Settings.clearYouTubeAuthorization()
    }
}

enum YouTubeStreamDiscovery {
    static func findStream(in data: Data, matchingStreamKey streamKey: String) throws -> YouTubeStream {
        guard let response = try? JSONDecoder().decode(
            YouTubeListResponse<YouTubeLiveStreamResource>.self,
            from: data
        ) else {
            throw YouTubeError.invalidResponse
        }

        return try findStream(in: response.items, matchingStreamKey: streamKey)
    }

    static func findStream(
        in items: [YouTubeLiveStreamResource],
        matchingStreamKey streamKey: String
    ) throws -> YouTubeStream {
        var matchingStreams: [YouTubeStream] = []
        var foundMatchingKey = false

        for item in items {
            guard let cdn = item.cdn,
                  let ingestionInfo = cdn.ingestionInfo,
                  let streamName = ingestionInfo.streamName,
                  streamName == streamKey else {
                continue
            }
            foundMatchingKey = true
            guard let ingestionType = cdn.ingestionType,
                  let ingestionAddress = ingestionInfo.ingestionAddress,
                  let id = item.id else {
                continue
            }
            matchingStreams.append(YouTubeStream(
                id: id,
                streamName: streamName,
                publishedAt: item.snippet?.publishedAt,
                ingestionType: ingestionType,
                ingestionAddress: ingestionAddress,
                backupIngestionAddress: ingestionInfo.backupIngestionAddress
            ))
        }

        if let newest = matchingStreams.max(by: { lhs, rhs in
            let lhsDate = lhs.publishedAt.flatMap(YouTubeTimestamp.parse) ?? .distantPast
            let rhsDate = rhs.publishedAt.flatMap(YouTubeTimestamp.parse) ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return lhs.id < rhs.id
        }) {
            return newest
        }

        throw foundMatchingKey ? YouTubeError.invalidResponse : YouTubeError.noStreamFound
    }

    static func hlsEndpoint(for stream: YouTubeStream) throws -> YouTubeHLSEndpoint {
        guard stream.ingestionType.lowercased() == "hls" else {
            throw YouTubeError.incompatibleIngestionType(stream.ingestionType)
        }
        guard let url = URL(string: stream.ingestionAddress) else {
            throw YouTubeError.invalidIngestionAddress
        }
        do {
            return try YouTubeHLSEndpoint(url)
        } catch {
            throw YouTubeError.invalidIngestionAddress
        }
    }
}

enum YouTubeTimestamp {
    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

enum YouTubeBroadcastDiscovery {
    static func selectCurrentOrUpcoming(
        from broadcasts: [YouTubeBroadcast]
    ) -> YouTubeBroadcast? {
        let eligible = broadcasts.filter { $0.isActive || $0.lifeCycleStatus == "ready" || $0.lifeCycleStatus == "created" }
        let active = eligible.filter(\.isActive)
        if let current = active.max(by: isOlder) {
            return current
        }
        // Prefer a ready event over an unconfigured upcoming broadcast.
        let ready = eligible.filter { $0.lifeCycleStatus == "ready" }
        if let upcoming = ready.max(by: isOlder) {
            return upcoming
        }
        return eligible.max(by: isOlder)
    }

    private static func isOlder(_ lhs: YouTubeBroadcast, _ rhs: YouTubeBroadcast) -> Bool {
        let lhsDate = recencyDate(for: lhs)
        let rhsDate = recencyDate(for: rhs)
        if lhsDate != rhsDate {
            return (lhsDate ?? .distantPast) < (rhsDate ?? .distantPast)
        }

        let lhsPriority = statusPriority(lhs.lifeCycleStatus)
        let rhsPriority = statusPriority(rhs.lifeCycleStatus)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        return lhs.id < rhs.id
    }

    private static func recencyDate(for broadcast: YouTubeBroadcast) -> Date? {
        [
            broadcast.actualStartTime,
            broadcast.scheduledStartTime,
            broadcast.publishedAt,
        ]
        .compactMap { $0 }
        .compactMap(YouTubeTimestamp.parse)
        .first
    }

    private static func statusPriority(_ status: String?) -> Int {
        switch status {
        case "live": return 5
        case "liveStarting": return 4
        case "testing": return 3
        case "testStarting": return 2
        case "ready": return 1
        case "created": return 0
        default: return -2
        }
    }
}

/// Stores identifiers only. OAuth grants isolate Google/Brand accounts; hashes
/// keep refresh tokens and stream keys out of UserDefaults and diagnostics.
@MainActor
final class YouTubeDiscoveryCache {
    static let shared = YouTubeDiscoveryCache(defaults: .standard)
    private let defaults: UserDefaults?
    private var identifiers: [String: String]
    var preparations: [String: Task<YouTubeStreamingPreparation, Error>] = [:]
    var streamSetups: [String: Task<YouTubeStream, Error>] = [:]

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        identifiers = defaults?.dictionary(forKey: "YouTubeDiscoveryIDs") as? [String: String] ?? [:]
    }

    static func scope(refreshToken: String) -> String {
        SHA256.hash(data: Data(refreshToken.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func key(scope: String, streamKey: String) -> String {
        scope + "/" + SHA256.hash(data: Data(streamKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func id(_ kind: String, for key: String) -> String? { identifiers[key + "/" + kind] }

    func setID(_ value: String?, kind: String, for key: String) {
        identifiers[key + "/" + kind] = value
        defaults?.set(identifiers, forKey: "YouTubeDiscoveryIDs")
    }

    func clear(scope: String) {
        for (key, task) in preparations where key.hasPrefix(scope + "/") { task.cancel() }
        streamSetups[scope]?.cancel()
        identifiers = identifiers.filter { !$0.key.hasPrefix(scope + "/") }
        defaults?.set(identifiers, forKey: "YouTubeDiscoveryIDs")
    }
}

// MARK: - YouTubeService

@Observable
@MainActor
final class YouTubeService {
    var isSignedIn: Bool = false
    private(set) var isLoading: Bool = false
    var errorMessage: String?
    private var loadingOperationCount = 0
    private let requestExecutor: YouTubeAPIRequestExecutor
    private let diagnostics: YouTubeDiagnostics
    private var tokenStore: any YouTubeTokenStoring
    private let discoveryCache: YouTubeDiscoveryCache
    private let now: @Sendable () -> Date
    private var authenticationSession: ASWebAuthenticationSession?
    private var tokenRefreshTask: Task<String, Error>?

    init(
        transport: any YouTubeAPITransport = URLSessionYouTubeAPITransport(),
        tokenStore: any YouTubeTokenStoring = SettingsYouTubeTokenStore(),
        discoveryCache: YouTubeDiscoveryCache = .shared,
        now: @escaping @Sendable () -> Date = Date.init,
        diagnostics: YouTubeDiagnostics = YouTubeDiagnostics()
    ) {
        requestExecutor = YouTubeAPIRequestExecutor(transport: transport, diagnostics: diagnostics)
        self.diagnostics = diagnostics
        self.tokenStore = tokenStore
        self.discoveryCache = discoveryCache
        self.now = now
        isSignedIn = tokenStore.refreshToken != nil
    }

    private func beginLoading() {
        loadingOperationCount += 1
        isLoading = true
        errorMessage = nil
    }

    private func endLoading() {
        loadingOperationCount = max(0, loadingOperationCount - 1)
        isLoading = loadingOperationCount > 0
    }

    private func matchingSelection(
        on page: [YouTubeBroadcastResource], streamKey: String, token: String
    ) async throws -> (broadcast: YouTubeBroadcast, stream: YouTubeStream)? {
        let broadcasts = page.compactMap(\.broadcast).filter {
            $0.isActive || $0.lifeCycleStatus == "ready" || $0.lifeCycleStatus == "created"
        }
        let streamIDs = Set(broadcasts.compactMap(\.boundStreamId).filter { !$0.isEmpty })
        guard !streamIDs.isEmpty else { return nil }

        // A broadcast page contains at most 50 distinct bound stream IDs.
        // Resolve only these streams, rather than enumerating the channel's history.
        var components = URLComponents(string: "\(YOUTUBE_API_BASE)/liveStreams")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "cdn,snippet"),
            URLQueryItem(name: "id", value: streamIDs.sorted().joined(separator: ",")),
            URLQueryItem(name: "maxResults", value: "50"),
        ]
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw YouTubeError.invalidResponse }
        let resources: YouTubeListResponse<YouTubeLiveStreamResource> = try await apiGet(
            url: url.absoluteString, token: token, operation: .streams
        )
        let matches = resources.items.filter {
            guard let id = $0.id, streamIDs.contains(id) else { return false }
            return $0.cdn?.ingestionInfo?.streamName == streamKey
        }
        diagnostics.log("YouTube stream discovery: \(resources.items.count) streams; \(matches.count) match the configured key", .debug)
        let matchingIDs = Set(matches.compactMap(\.id))
        let matchingBroadcasts = broadcasts.filter {
            $0.boundStreamId.map { matchingIDs.contains($0) } == true
        }
        diagnostics.log("YouTube broadcast discovery: \(page.count) broadcasts; \(matchingBroadcasts.count) bound to the matching stream", .debug)
        guard let broadcast = YouTubeBroadcastDiscovery.selectCurrentOrUpcoming(from: matchingBroadcasts) else {
            return nil
        }
        let stream = try YouTubeStreamDiscovery.findStream(
            in: matches.filter { $0.id == broadcast.boundStreamId }, matchingStreamKey: streamKey
        )
        return (broadcast, stream)
    }

    // MARK: - OAuth2 Authentication

    func signIn() async {
        diagnostics.log("YouTube OAuth: starting sign-in (shared browser session; consent requested)", .debug)
        guard YOUTUBE_CLIENT_ID != "YOUR_GOOGLE_OAUTH2_CLIENT_ID" else {
            errorMessage = "YouTube Client ID not configured in Constants.swift"
            LOG("YouTube Client ID not configured", level: .error)
            return
        }

        authenticationSession?.cancel()
        authenticationSession = nil

        let codeVerifier: String
        let oauthState: String
        do {
            codeVerifier = try generateCodeVerifier()
            oauthState = try generateRandomURLSafeString(byteCount: 32)
        } catch {
            errorMessage = error.localizedDescription
            LOG("YouTube sign-in could not generate secure random data", level: .error)
            return
        }
        let codeChallenge = generateCodeChallenge(from: codeVerifier)

        var components = URLComponents(string: YOUTUBE_AUTH_URL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: YOUTUBE_CLIENT_ID),
            URLQueryItem(name: "redirect_uri", value: YOUTUBE_REDIRECT_URI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: YOUTUBE_SCOPES),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: oauthState),
        ]

        guard let authURL = components.url else {
            errorMessage = "Failed to construct auth URL"
            return
        }

        do {
            let callbackURL = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    let continuationGate = AuthenticationContinuation(continuation)
                    let session = ASWebAuthenticationSession(
                        url: authURL,
                        callbackURLScheme: YOUTUBE_REDIRECT_SCHEME
                    ) { url, error in
                        if let error = error {
                            continuationGate.resume(throwing: error)
                        } else if let url = url {
                            continuationGate.resume(returning: url)
                        } else {
                            continuationGate.resume(throwing: YouTubeError.authFailed("No URL returned"))
                        }
                    }
                    session.prefersEphemeralWebBrowserSession = false
                    session.presentationContextProvider = ASWebAuthPresentationContext.shared
                    authenticationSession = session
                    guard session.start() else {
                        authenticationSession = nil
                        continuationGate.resume(
                            throwing: YouTubeError.authFailed("Could not start the authentication session")
                        )
                        return
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.authenticationSession?.cancel()
                    self?.authenticationSession = nil
                }
            }
            authenticationSession = nil

            let callbackComponents = URLComponents(
                url: callbackURL,
                resolvingAgainstBaseURL: false
            )
            guard callbackComponents?.queryItems?.first(where: { $0.name == "state" })?.value == oauthState else {
                throw YouTubeError.authFailed("The authentication response could not be verified")
            }
            if let callbackError = callbackComponents?.queryItems?.first(where: { $0.name == "error" })?.value {
                throw YouTubeError.authFailed(callbackError)
            }

            guard let code = callbackComponents?.queryItems?
                .first(where: { $0.name == "code" })?.value else {
                throw YouTubeError.authFailed("No authorization code received")
            }

            diagnostics.log("YouTube OAuth: callback verified; authorization code received", .debug)
            try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)
            isSignedIn = true
            errorMessage = nil
            LOG("Signed in to YouTube successfully", level: .debug)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            authenticationSession = nil
            LOG("YouTube sign-in cancelled by user", level: .debug)
        } catch {
            authenticationSession = nil
            let message = YouTubeDiagnostics.text(error.localizedDescription, secrets: [
                codeVerifier, oauthState, tokenStore.accessToken ?? "", tokenStore.refreshToken ?? "",
            ])
            errorMessage = message
            LOG("YouTube sign-in failed: \(message)", level: .error)
        }
    }

    @discardableResult
    func signOut() -> Bool {
        authenticationSession?.cancel()
        authenticationSession = nil
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        do {
            let scope = try? authorizationScope()
            try tokenStore.clearAuthorization()
            if let scope { discoveryCache.clear(scope: scope) }
            isSignedIn = false
            errorMessage = nil
            LOG("Signed out of YouTube", level: .debug)
            return true
        } catch {
            errorMessage = "Could not remove YouTube authorization: \(error.localizedDescription)"
            LOG("Could not remove YouTube authorization from Keychain", level: .error)
            return false
        }
    }

    // MARK: - Token Management

    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws {
        let body: [String: String] = [
            "code": code,
            "client_id": YOUTUBE_CLIENT_ID,
            "redirect_uri": YOUTUBE_REDIRECT_URI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier,
        ]

        let tokenData = try await postForm(url: YOUTUBE_TOKEN_URL, body: body, operation: .exchangeCode)
        try parseAndStoreTokens(from: tokenData, operation: .exchangeCode)
    }

    private func performAccessTokenRefresh() async throws -> String {
        guard let refreshToken = tokenStore.refreshToken else {
            throw YouTubeError.notSignedIn
        }

        let body: [String: String] = [
            "client_id": YOUTUBE_CLIENT_ID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]

        let tokenData = try await postForm(url: YOUTUBE_TOKEN_URL, body: body, operation: .refreshToken)
        try parseAndStoreTokens(from: tokenData, operation: .refreshToken)
        guard let token = tokenStore.accessToken else {
            throw YouTubeError.tokenRefreshFailed
        }
        return token
    }

    private func refreshAccessToken() async throws -> String {
        if let tokenRefreshTask {
            return try await tokenRefreshTask.value
        }

        let task = Task { @MainActor in
            try await self.performAccessTokenRefresh()
        }
        tokenRefreshTask = task
        do {
            let token = try await task.value
            tokenRefreshTask = nil
            return token
        } catch {
            tokenRefreshTask = nil
            throw error
        }
    }

    private func parseAndStoreTokens(from data: Data, operation: YouTubeAPIOperation) throws {
        let response = try requestExecutor.decode(YouTubeTokenResponse.self, from: data, operation: operation)
        if let error = response.error {
            let description = response.errorDescription ?? error
            throw YouTubeError.authFailed(description)
        }
        guard let accessToken = response.accessToken else {
            throw YouTubeError.invalidResponse
        }
        let expiresIn = response.expiresIn ?? 3600

        // Refresh token is only returned on initial authorization, not on refresh
        if let refreshToken = response.refreshToken {
            try tokenStore.setRefreshToken(refreshToken)
        }
        try tokenStore.setAccessToken(accessToken)
        tokenStore.expiry = now().addingTimeInterval(TimeInterval(expiresIn - 60))
        let granted = response.scope.map { Set($0.split(separator: " ").map(String.init)) }
        let requested = Set(YOUTUBE_SCOPES.split(separator: " ").map(String.init))
        let scopeStatus = granted.map { requested.isSubset(of: $0) ? "all requested scopes granted" : "some requested scopes missing" }
            ?? "granted scopes not returned"
        diagnostics.log("YouTube \(operation.rawValue): credentials stored; refresh token present=\(tokenStore.refreshToken != nil); \(scopeStatus)", .debug)
    }

    private func getValidAccessToken() async throws -> String {
        if let token = tokenStore.accessToken,
           let expiry = tokenStore.expiry,
           now() < expiry {
            return token
        }
        return try await refreshAccessToken()
    }

    // MARK: - YouTube API: Streams

    /// The extra channel lookup is best-effort diagnostics for Settings only.
    /// It must not prevent normal discovery or change streaming preflight.
    func loadSettingsConfiguration(forStreamKey streamKey: String) async throws
        -> (broadcast: YouTubeBroadcast, playlists: [YouTubePlaylist]) {
        beginLoading()
        defer { endLoading() }
        diagnostics.log("YouTube Settings: loading configuration; saved authorization present=\(tokenStore.refreshToken != nil)", .debug)
        let token = try await getValidAccessToken()
        try await logAuthorizedChannel(token: token, streamKey: streamKey)
        try Task.checkCancellation()
        let selection = try await selectedBroadcast(forStreamKey: streamKey)
        let broadcast = selection.broadcast ?? .draft(for: selection.stream)
        let playlists = try await listPlaylists()
        diagnostics.log("YouTube Settings: configuration loaded; broadcast=\(YouTubeDiagnostics.text(broadcast.statusLabel)); \(playlists.count) playlists", .info)
        return (broadcast, playlists)
    }

    private func logAuthorizedChannel(token: String, streamKey: String) async throws {
        do {
            let url = URL(string: "\(YOUTUBE_API_BASE)/channels?part=snippet&mine=true&maxResults=50&fields=items(id,snippet/title),nextPageToken")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 5
            // Observe the current authorization without refreshing or retrying
            // solely for a diagnostic request. Normal discovery owns recovery.
            let channels = try await requestExecutor.decode(
                YouTubeListResponse<YouTubeChannelResource>.self,
                for: request, operation: .channels
            )
            try Task.checkCancellation()
            let secrets = [streamKey, tokenStore.accessToken ?? "", tokenStore.refreshToken ?? ""]
            diagnostics.log("YouTube authorized channel lookup: \(channels.items.count) returned; more pages=\(channels.nextPageToken != nil)", .debug)
            for channel in channels.items.prefix(50) {
                let name = YouTubeDiagnostics.text(channel.snippet?.title ?? "(no title)", secrets: secrets)
                let id = YouTubeDiagnostics.text(channel.id ?? "(no ID)", secrets: secrets)
                diagnostics.log("YouTube authorized channel: \(name) [\(id)]", .debug)
            }
            if channels.items.isEmpty {
                diagnostics.log("YouTube: no channel returned for this authorization; check the channel selected in Google sign-in", .warning)
            }
        } catch {
            if YouTubeDiagnostics.failure(error) == "cancelled" { throw error }
            diagnostics.log("YouTube authorized channel check unavailable (\(YouTubeDiagnostics.failure(error))); continuing normal stream discovery", .warning)
        }
    }

    func findHLSIngestionEndpoint(forStreamKey streamKey: String) async throws -> YouTubeHLSEndpoint {
        beginLoading()
        defer { endLoading() }

        let selection = try await selectedBroadcast(forStreamKey: streamKey)
        return try YouTubeStreamDiscovery.hlsEndpoint(for: selection.stream)
    }

    func findBroadcastForStreamKey(_ streamKey: String) async throws -> YouTubeBroadcast {
        beginLoading()
        defer { endLoading() }

        guard let broadcast = try await selectedBroadcast(forStreamKey: streamKey).broadcast else {
            throw YouTubeError.noBroadcastFound
        }
        return broadcast
    }

    func prepareForStreaming(
        streamKey: String,
        preferences: YouTubeBroadcastPreferences? = nil,
        thumbnailData: Data? = nil
    ) async throws -> YouTubeStreamingPreparation {
        beginLoading()
        defer { endLoading() }

        let scope = try authorizationScope()
        let key = YouTubeDiscoveryCache.key(scope: scope, streamKey: streamKey)
        if let existing = discoveryCache.preparations[key] { return try await existing.value }
        let task = Task { @MainActor in
            try await self.performStreamingPreparation(
                streamKey: streamKey, preferences: preferences, thumbnailData: thumbnailData, scope: scope
            )
        }
        discoveryCache.preparations[key] = task
        defer { discoveryCache.preparations[key] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performStreamingPreparation(
        streamKey: String, preferences: YouTubeBroadcastPreferences?, thumbnailData: Data?, scope: String
    ) async throws -> YouTubeStreamingPreparation {
        let selection = try await selectedBroadcast(forStreamKey: streamKey)
        let endpoint = try YouTubeStreamDiscovery.hlsEndpoint(for: selection.stream)
        try checkAuthorization(scope)
        var broadcast: YouTubeBroadcast
        if let current = selection.broadcast {
            broadcast = current
        } else {
            var template = YouTubeBroadcast.draft(for: selection.stream)
            if let preferences, preferences.streamId == selection.stream.id {
                template = preferences.applying(to: template)
            }
            broadcast = try await createOrResumeBroadcast(template: template, stream: selection.stream, scope: scope)
        }
        guard broadcast.lifeCycleStatus == "ready" else {
            throw YouTubeError.broadcastNotReady(broadcast.statusLabel.lowercased())
        }
        let applicablePreferences = preferences?.streamId == selection.stream.id
            ? preferences
            : nil
        var preparedBroadcast = applicablePreferences?.applying(to: broadcast) ?? broadcast
        if selection.broadcast == nil {
            // App-created events go live on ingestion without a Studio preview
            // or manual transition, even if an older saved template used one.
            preparedBroadcast.enableAutoStart = true
            preparedBroadcast.enableMonitorStream = false
            preparedBroadcast.broadcastStreamDelayMs = 0
        }
        // YouTube owns the final broadcast transition after Tubeist has drained
        // and closed HLS ingestion. Its backend has the only authoritative view
        // of when the final accepted media is safe to archive.
        preparedBroadcast.enableAutoStop = true
        if preparedBroadcast != broadcast {
            try await updateBroadcast(
                id: broadcast.id,
                title: preparedBroadcast.title,
                privacyStatus: preparedBroadcast.privacyStatus,
                scheduledStartTime: broadcast.scheduledStartTime,
                enableDvr: preparedBroadcast.enableDvr,
                latencyPreference: preparedBroadcast.latencyPreference,
                enableMonitorStream: preparedBroadcast.enableMonitorStream,
                broadcastStreamDelayMs: preparedBroadcast.broadcastStreamDelayMs,
                enableEmbed: preparedBroadcast.enableEmbed,
                recordFromStart: preparedBroadcast.recordFromStart,
                enableAutoStart: preparedBroadcast.enableAutoStart,
                enableAutoStop: true,
                selfDeclaredMadeForKids: preparedBroadcast.selfDeclaredMadeForKids
            )
            broadcast = preparedBroadcast
        }
        if let preferences = applicablePreferences {
            if let thumbnailData {
                try await uploadThumbnail(videoId: broadcast.id, imageData: thumbnailData)
            }
            if let playlistId = preferences.playlistId {
                try await addToPlaylist(playlistId: playlistId, videoId: broadcast.id)
            }
        }
        return YouTubeStreamingPreparation(
            endpoint: endpoint,
            broadcast: broadcast
        )
    }

    private func authorizationScope() throws -> String {
        guard let refreshToken = tokenStore.refreshToken else { throw YouTubeError.notSignedIn }
        return YouTubeDiscoveryCache.scope(refreshToken: refreshToken)
    }

    private func checkAuthorization(_ scope: String) throws {
        try Task.checkCancellation()
        guard try authorizationScope() == scope else { throw YouTubeError.notSignedIn }
    }

    private func resourceURL(_ resource: String, query: [URLQueryItem]) throws -> String {
        var components = URLComponents(string: "\(YOUTUBE_API_BASE)/\(resource)")!
        components.queryItems = query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw YouTubeError.invalidResponse }
        return url.absoluteString
    }

    private func streamByID(_ id: String, token: String) async throws -> YouTubeLiveStreamResource? {
        let url = try resourceURL("liveStreams", query: [
            .init(name: "part", value: "cdn,snippet"), .init(name: "id", value: id)
        ])
        let page: YouTubeListResponse<YouTubeLiveStreamResource> = try await apiGet(url: url, token: token, operation: .streams)
        return page.items.first { $0.id == id }
    }

    private func selectedBroadcast(
        forStreamKey streamKey: String
    ) async throws -> (broadcast: YouTubeBroadcast?, stream: YouTubeStream) {
        let scope = try authorizationScope()
        let key = YouTubeDiscoveryCache.key(scope: scope, streamKey: streamKey)
        let token = try await getValidAccessToken()
        var knownStream: YouTubeStream?
        if let id = discoveryCache.id("stream", for: key) {
            // Validate ownership/access and the exact key; stale entries are hints only.
            if let resource = try await streamByID(id, token: token), resource.cdn?.ingestionInfo?.streamName == streamKey {
                knownStream = try YouTubeStreamDiscovery.findStream(in: [resource], matchingStreamKey: streamKey)
                diagnostics.log("YouTube stream discovery: validated remembered stream ID", .debug)
            } else {
                try checkAuthorization(scope)
                discoveryCache.setID(nil, kind: "stream", for: key)
            }
        }
        // Never enumerate completed broadcasts. Active matches take precedence.
        for status in ["active", "upcoming"] {
            diagnostics.log("YouTube broadcast discovery: searching \(status) broadcasts", .debug)
            let url = "\(YOUTUBE_API_BASE)/liveBroadcasts?part=snippet,contentDetails,status&broadcastStatus=\(status)&broadcastType=all&maxResults=50"
            var selection: (broadcast: YouTubeBroadcast, stream: YouTubeStream)?
            let _: [YouTubeBroadcastResource] = try await paginatedItems(
                url: url, token: token, operation: .broadcasts,
                stopAfterPage: { page in
                    if let knownStream {
                        if let broadcast = YouTubeBroadcastDiscovery.selectCurrentOrUpcoming(
                            from: page.compactMap(\.broadcast).filter { $0.boundStreamId == knownStream.id }
                        ) {
                            selection = (broadcast, knownStream)
                        }
                    } else {
                        selection = try await self.matchingSelection(on: page, streamKey: streamKey, token: token)
                    }
                    return selection != nil
                }
            )
            if let selection {
                try checkAuthorization(scope)
                discoveryCache.setID(selection.stream.id, kind: "stream", for: key)
                diagnostics.log("YouTube broadcast selected; status=\(YouTubeDiagnostics.text(selection.broadcast.statusLabel))", .debug)
                return selection
            }
        }
        // A pasted key may have no current broadcast. Resolve it once, checking
        // each page before advancing; subsequent loads use the remembered ID.
        if knownStream == nil {
            var found: YouTubeStream?
            let _: [YouTubeLiveStreamResource] = try await paginatedItems(
                url: "\(YOUTUBE_API_BASE)/liveStreams?part=cdn,snippet&mine=true&maxResults=50",
                token: token, operation: .streams, stopAfterPage: { page in
                    guard page.contains(where: { $0.cdn?.ingestionInfo?.streamName == streamKey }) else { return false }
                    found = try YouTubeStreamDiscovery.findStream(in: page, matchingStreamKey: streamKey)
                    return true
                }
            )
            knownStream = found
        }
        guard let stream = knownStream else { throw YouTubeError.noStreamFound }
        try checkAuthorization(scope)
        discoveryCache.setID(stream.id, kind: "stream", for: key)
        return (nil, stream)
    }

    /// Explicit Settings action. Reuses the app-created key, including after a
    /// cancelled Settings edit, rather than creating another key on each visit.
    func setUpStream() async throws -> YouTubeStream {
        beginLoading()
        defer { endLoading() }
        let scope = try authorizationScope()
        if let task = discoveryCache.streamSetups[scope] { return try await task.value }
        let task = Task { @MainActor in try await self.performStreamSetup(scope: scope) }
        discoveryCache.streamSetups[scope] = task
        defer { discoveryCache.streamSetups[scope] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performStreamSetup(scope: String) async throws -> YouTubeStream {
        let token = try await getValidAccessToken()
        try checkAuthorization(scope)
        var resource: YouTubeLiveStreamResource?
        if let id = discoveryCache.id("managedStream", for: scope) {
            resource = try await streamByID(id, token: token)
        }
        if resource == nil {
            try checkAuthorization(scope)
            resource = try await apiPost(
                url: "\(YOUTUBE_API_BASE)/liveStreams?part=snippet,cdn,contentDetails",
                token: token, jsonBody: JSONSerialization.data(withJSONObject: [
                    "snippet": ["title": "Tubeist"],
                    "cdn": ["ingestionType": "hls", "resolution": "variable", "frameRate": "variable"],
                    "contentDetails": ["isReusable": true]
                ]), operation: .createStream
            )
        }
        try checkAuthorization(scope)
        guard let resource, let id = resource.id, !id.isEmpty,
              let streamKey = resource.cdn?.ingestionInfo?.streamName, !streamKey.isEmpty else {
            throw YouTubeError.invalidResponse
        }
        let stream = try YouTubeStreamDiscovery.findStream(in: [resource], matchingStreamKey: streamKey)
        _ = try YouTubeStreamDiscovery.hlsEndpoint(for: stream)
        discoveryCache.setID(id, kind: "managedStream", for: scope)
        discoveryCache.setID(id, kind: "stream", for: YouTubeDiscoveryCache.key(scope: scope, streamKey: streamKey))
        diagnostics.log("YouTube: reusable HLS stream configured", .debug)
        return stream
    }

    private func createOrResumeBroadcast(template: YouTubeBroadcast, stream: YouTubeStream, scope: String) async throws -> YouTubeBroadcast {
        let key = YouTubeDiscoveryCache.key(scope: scope, streamKey: stream.streamName)
        let token = try await getValidAccessToken()
        var pending: YouTubeBroadcast?
        if let id = discoveryCache.id("createdBroadcast", for: key) {
            // A successful insert followed by a failed bind must not create a
            // duplicate on retry. Read only that known event, never its history.
            let url = try resourceURL("liveBroadcasts", query: [
                .init(name: "part", value: "snippet,status,contentDetails"), .init(name: "id", value: id)
            ])
            let page: YouTubeListResponse<YouTubeBroadcastResource> = try await apiGet(url: url, token: token, operation: .broadcasts)
            pending = page.items.first { $0.id == id }?.broadcast
            if let broadcast = pending, broadcast.lifeCycleStatus == "complete" || broadcast.lifeCycleStatus == "revoked" {
                pending = nil
            }
        }
        try checkAuthorization(scope)
        if let broadcast = pending, broadcast.boundStreamId == stream.id {
            return broadcast
        }
        if let broadcast = pending {
            guard broadcast.lifeCycleStatus == "created", broadcast.boundStreamId == nil else {
                throw YouTubeError.broadcastNotReady(broadcast.statusLabel.lowercased())
            }
        } else {
            var status: [String: Any] = ["privacyStatus": template.privacyStatus]
            if let madeForKids = template.selfDeclaredMadeForKids { status["selfDeclaredMadeForKids"] = madeForKids }
            let inserted: YouTubeBroadcastResource = try await apiPost(
                url: "\(YOUTUBE_API_BASE)/liveBroadcasts?part=snippet,status,contentDetails", token: token,
                jsonBody: JSONSerialization.data(withJSONObject: [
                    "snippet": ["title": template.title, "scheduledStartTime": ISO8601DateFormatter().string(from: now().addingTimeInterval(10))],
                    "status": status,
                    "contentDetails": [
                        "enableDvr": template.enableDvr, "latencyPreference": template.latencyPreference,
                        "monitorStream": ["enableMonitorStream": false, "broadcastStreamDelayMs": 0],
                        "enableEmbed": template.enableEmbed, "recordFromStart": template.recordFromStart,
                        "enableAutoStart": true, "enableAutoStop": true
                    ]
                ]), operation: .createBroadcast
            )
            try checkAuthorization(scope)
            guard let id = inserted.id, !id.isEmpty else { throw YouTubeError.invalidResponse }
            discoveryCache.setID(id, kind: "createdBroadcast", for: key)
            guard let broadcast = inserted.broadcast else { throw YouTubeError.invalidResponse }
            pending = broadcast
        }
        guard let pending else { throw YouTubeError.invalidResponse }
        try checkAuthorization(scope)
        let url = try resourceURL("liveBroadcasts/bind", query: [
            .init(name: "id", value: pending.id), .init(name: "streamId", value: stream.id),
            .init(name: "part", value: "snippet,status,contentDetails")
        ])
        let bound: YouTubeBroadcastResource = try await apiPost(url: url, token: token, jsonBody: Data(), operation: .bindBroadcast)
        try checkAuthorization(scope)
        guard let broadcast = bound.broadcast, broadcast.id == pending.id, broadcast.boundStreamId == stream.id else {
            throw YouTubeError.invalidResponse
        }
        diagnostics.log("YouTube: created and bound the next broadcast", .debug)
        return broadcast
    }

    // MARK: - YouTube API: Update Broadcast

    func updateBroadcast(id: String, title: String, privacyStatus: String, scheduledStartTime: String?, enableDvr: Bool, latencyPreference: String, enableMonitorStream: Bool, broadcastStreamDelayMs: Int, enableEmbed: Bool, recordFromStart: Bool, enableAutoStart: Bool, enableAutoStop: Bool, selfDeclaredMadeForKids: Bool? = nil) async throws {
        beginLoading()
        defer { endLoading() }

        let token = try await getValidAccessToken()
        let url = "\(YOUTUBE_API_BASE)/liveBroadcasts?part=snippet,status,contentDetails"

        var snippet: [String: Any] = ["title": title]
        if let scheduledStartTime {
            snippet["scheduledStartTime"] = scheduledStartTime
        }

        var status: [String: Any] = ["privacyStatus": privacyStatus]
        if let selfDeclaredMadeForKids { status["selfDeclaredMadeForKids"] = selfDeclaredMadeForKids }
        let body: [String: Any] = [
            "id": id,
            "snippet": snippet,
            "status": status,
            "contentDetails": [
                "enableDvr": enableDvr,
                "latencyPreference": latencyPreference,
                "monitorStream": [
                    "enableMonitorStream": enableMonitorStream,
                    "broadcastStreamDelayMs": broadcastStreamDelayMs,
                ],
                "enableEmbed": enableEmbed,
                "recordFromStart": recordFromStart,
                "enableAutoStart": enableAutoStart,
                "enableAutoStop": enableAutoStop,
            ],
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let resource: YouTubeBroadcastResource = try await apiPut(
            url: url,
            token: token,
            jsonBody: jsonData,
            operation: .updateBroadcast
        )
        guard resource.id == id else {
            throw YouTubeError.invalidResponse
        }

        LOG("Updated YouTube broadcast: \(title) (\(privacyStatus))", level: .debug)
    }

    // MARK: - YouTube API: Broadcast Status (lightweight, 1 unit)

    func fetchBroadcastStatus(broadcastId: String) async throws -> String? {
        let token = try await getValidAccessToken()
        let url = "\(YOUTUBE_API_BASE)/liveBroadcasts?part=status&id=\(broadcastId)"
        let response: YouTubeListResponse<YouTubeBroadcastResource> = try await apiGet(
            url: url,
            token: token,
            operation: .broadcastStatus
        )
        return response.items.first?.status?.lifeCycleStatus
    }

    // MARK: - YouTube API: Transition (Stop)

    func stopBroadcast(id: String) async throws {
        beginLoading()
        defer { endLoading() }

        let token = try await getValidAccessToken()
        try await transitionBroadcastToComplete(id: id, token: token)
    }

    private func transitionBroadcastToComplete(id: String, token: String) async throws {
        let url = "\(YOUTUBE_API_BASE)/liveBroadcasts/transition?broadcastStatus=complete&id=\(id)&part=status"
        let resource: YouTubeBroadcastResource = try await apiPost(
            url: url,
            token: token,
            jsonBody: Data(),
            operation: .transitionBroadcast
        )
        guard resource.id == id,
              resource.status?.lifeCycleStatus == "complete" else {
            throw YouTubeError.invalidResponse
        }

        LOG("Stopped YouTube broadcast \(id)", level: .debug)
    }

    // MARK: - YouTube API: Thumbnail

    func uploadThumbnail(videoId: String, imageData: Data) async throws {
        beginLoading()
        defer { endLoading() }

        let token = try await getValidAccessToken()
        let urlString = "https://www.googleapis.com/upload/youtube/v3/thumbnails/set?videoId=\(videoId)&uploadType=media"
        guard let url = URL(string: urlString) else {
            throw YouTubeError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("\(imageData.count)", forHTTPHeaderField: "Content-Length")
        request.httpBody = imageData

        request.timeoutInterval = 30
        _ = try await authenticatedData(for: request, fallbackToken: token, operation: .thumbnail)

        LOG("Uploaded thumbnail for broadcast \(videoId)", level: .debug)
    }

    // MARK: - YouTube API: Playlists

    func listPlaylists() async throws -> [YouTubePlaylist] {
        beginLoading()
        defer { endLoading() }

        let token = try await getValidAccessToken()
        let url = "\(YOUTUBE_API_BASE)/playlists?part=snippet&mine=true&maxResults=50"
        let items: [YouTubePlaylistResource] = try await paginatedItems(
            url: url,
            token: token,
            operation: .playlists
        )

        return items.compactMap { item in
            guard let id = item.id,
                  let title = item.snippet?.title else {
                return nil
            }
            return YouTubePlaylist(id: id, title: title)
        }
    }

    func addToPlaylist(playlistId: String, videoId: String) async throws {
        beginLoading()
        defer { endLoading() }

        let token = try await getValidAccessToken()
        var lookupComponents = URLComponents(string: "\(YOUTUBE_API_BASE)/playlistItems")
        lookupComponents?.queryItems = [
            URLQueryItem(name: "part", value: "id"),
            URLQueryItem(name: "playlistId", value: playlistId),
            URLQueryItem(name: "videoId", value: videoId),
            URLQueryItem(name: "maxResults", value: "1"),
        ]
        guard let lookupURL = lookupComponents?.url else {
            throw YouTubeError.invalidResponse
        }
        let existing: YouTubeListResponse<YouTubeIdentifierResource> = try await apiGet(
            url: lookupURL.absoluteString,
            token: token,
            operation: .playlistItems
        )
        if !existing.items.isEmpty {
            LOG("Broadcast is already in playlist \(playlistId)", level: .debug)
            return
        }

        let url = "\(YOUTUBE_API_BASE)/playlistItems?part=snippet"

        let body: [String: Any] = [
            "snippet": [
                "playlistId": playlistId,
                "resourceId": [
                    "kind": "youtube#video",
                    "videoId": videoId,
                ],
            ],
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        LOG("Adding video \(videoId) to playlist \(playlistId)", level: .debug)
        let inserted: YouTubeIdentifierResource = try await apiPost(
            url: url,
            token: token,
            jsonBody: jsonData,
            operation: .insertPlaylistItem
        )
        guard inserted.id != nil else {
            throw YouTubeError.invalidResponse
        }

        LOG("Added broadcast to playlist \(playlistId)", level: .debug)
    }

    // MARK: - HTTP Helpers

    private func apiGet<Response: Decodable & Sendable>(
        url: String,
        token: String,
        operation: YouTubeAPIOperation
    ) async throws -> Response {
        guard let requestURL = URL(string: url) else {
            throw YouTubeError.invalidResponse
        }
        var request = URLRequest(url: requestURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let data = try await authenticatedData(for: request, fallbackToken: token, operation: operation)
        return try requestExecutor.decode(Response.self, from: data, operation: operation)
    }

    private func paginatedItems<Item: Decodable & Sendable>(
        url: String,
        token: String,
        operation: YouTubeAPIOperation,
        stopAfterPage: @MainActor ([Item]) async throws -> Bool = { _ in false }
    ) async throws -> [Item] {
        guard let baseComponents = URLComponents(string: url) else {
            throw YouTubeError.invalidResponse
        }

        var items: [Item] = []
        var pageToken: String?
        var seenPageTokens: Set<String> = []
        var pageNumber = 0

        repeat {
            var components = baseComponents
            if let pageToken {
                components.queryItems = (components.queryItems ?? []) + [
                    URLQueryItem(name: "pageToken", value: pageToken),
                ]
            }
            // Page tokens are opaque. URLComponents leaves '+' literal, but
            // form-style query decoders interpret it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
            guard let pageURL = components.url else {
                throw YouTubeError.invalidResponse
            }

            let page: YouTubeListResponse<Item>
            do {
                page = try await apiGet(url: pageURL.absoluteString, token: token, operation: operation)
            } catch {
                let failure = YouTubeDiagnostics.failure(error)
                if failure != "cancelled" {
                    // Report token characteristics, never the token itself.
                    diagnostics.log("YouTube \(operation.rawValue): page \(pageNumber + 1) failed after \(items.count) items; page token present=\(pageToken != nil); token contains plus=\(pageToken?.contains("+") == true); \(failure)", .error)
                }
                throw error
            }
            pageNumber += 1
            diagnostics.log("YouTube \(operation.rawValue): page \(pageNumber), \(page.items.count) items; more pages=\(page.nextPageToken?.isEmpty == false)", .debug)
            items.append(contentsOf: page.items)
            if try await stopAfterPage(page.items) {
                diagnostics.log("YouTube \(operation.rawValue): matched on page \(pageNumber); stopping discovery", .debug)
                break
            }

            guard let nextPageToken = page.nextPageToken,
                  !nextPageToken.isEmpty else {
                pageToken = nil
                continue
            }
            guard seenPageTokens.insert(nextPageToken).inserted else {
                diagnostics.log("YouTube \(operation.rawValue): repeated pagination token", .error)
                throw YouTubeError.invalidResponse
            }
            pageToken = nextPageToken
        } while pageToken != nil

        return items
    }

    private func apiPut<Response: Decodable & Sendable>(
        url: String,
        token: String,
        jsonBody: Data,
        operation: YouTubeAPIOperation
    ) async throws -> Response {
        guard let requestURL = URL(string: url) else {
            throw YouTubeError.invalidResponse
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonBody
        request.timeoutInterval = 30
        let data = try await authenticatedData(for: request, fallbackToken: token, operation: operation)
        return try requestExecutor.decode(Response.self, from: data, operation: operation)
    }

    private func apiPost<Response: Decodable & Sendable>(
        url: String,
        token: String,
        jsonBody: Data,
        operation: YouTubeAPIOperation
    ) async throws -> Response {
        guard let requestURL = URL(string: url) else {
            throw YouTubeError.invalidResponse
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonBody
        request.timeoutInterval = 30
        let data = try await authenticatedData(for: request, fallbackToken: token, operation: operation)
        return try requestExecutor.decode(Response.self, from: data, operation: operation)
    }

    private func postForm(url: String, body: [String: String], operation: YouTubeAPIOperation) async throws -> Data {
        guard let requestURL = URL(string: url) else {
            throw YouTubeError.invalidResponse
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoder.encode(body)
        request.timeoutInterval = 30
        return try await requestExecutor.data(for: request, operation: operation)
    }

    private func authenticatedData(
        for originalRequest: URLRequest,
        fallbackToken: String,
        operation: YouTubeAPIOperation
    ) async throws -> Data {
        var request = originalRequest
        var token = fallbackToken

        for attempt in 0...1 {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            do {
                return try await requestExecutor.data(for: request, operation: operation)
            } catch YouTubeError.apiError(let statusCode, _) where statusCode == 401 && attempt == 0 {
                diagnostics.log("YouTube \(operation.rawValue): HTTP 401; refreshing authorization before one retry", .warning)
                token = try await refreshAccessToken()
            }
        }
        throw YouTubeError.tokenRefreshFailed
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() throws -> String {
        try generateRandomURLSafeString(byteCount: 32)
    }

    private func generateRandomURLSafeString(byteCount: Int) throws -> String {
        var buffer = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer) == errSecSuccess else {
            throw YouTubeError.authFailed("Secure random generation failed")
        }
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return verifier }
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - UIImage Thumbnail Resizing

extension UIImage {
    func scaledToFit(maxWidth: CGFloat, maxHeight: CGFloat) -> UIImage? {
        let widthRatio = maxWidth / size.width
        let heightRatio = maxHeight / size.height
        let scale = min(widthRatio, heightRatio)
        guard scale < 1 else { return self }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    func jpegDataWithinLimit(maxBytes: Int) -> Data? {
        guard maxBytes > 0 else { return nil }
        var quality: CGFloat = 0.9
        while quality >= 0.1 {
            if let data = jpegData(compressionQuality: quality), data.count <= maxBytes {
                return data
            }
            quality -= 0.1
        }
        return nil
    }
}

private final class AuthenticationContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(_ continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
    }

    func resume(returning url: URL) {
        take()?.resume(returning: url)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<URL, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}

// MARK: - ASWebAuthenticationSession Presentation Context

@MainActor
final class ASWebAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding, Sendable {
    static let shared = ASWebAuthPresentationContext()

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first else {
                return ASPresentationAnchor()
            }
            return window
        }
    }
}
