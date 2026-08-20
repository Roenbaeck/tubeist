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

    var isLive: Bool { lifeCycleStatus == "live" }
    var isTesting: Bool { lifeCycleStatus == "testing" }
    var isActive: Bool { isLive || isTesting }

    var statusLabel: String {
        Self.label(for: lifeCycleStatus)
    }

    static func label(for status: String?) -> String {
        switch status {
        case "ready": return "Ready"
        case "testing": return "Testing"
        case "live": return "Live"
        case "complete": return "Complete"
        case "revoked": return "Revoked"
        case "created": return "Created"
        default: return status ?? "Unknown"
        }
    }

    var statusColor: String {
        switch lifeCycleStatus {
        case "live": return "red"
        case "testing": return "orange"
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

struct YouTubeListResponse<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
    let nextPageToken: String?
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
            enableAutoStop: contentDetails?.enableAutoStop ?? true
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

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case error
        case errorDescription = "error_description"
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
    static func selectCurrentOrMostRecent(
        from broadcasts: [YouTubeBroadcast]
    ) -> YouTubeBroadcast? {
        let eligible = broadcasts.filter { $0.lifeCycleStatus != "revoked" }
        let active = eligible.filter(\.isActive)
        return (active.isEmpty ? eligible : active).max(by: isOlder)
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
        case "testing": return 4
        case "ready": return 3
        case "created": return 2
        case "complete": return 1
        case "revoked": return 0
        default: return 0
        }
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
    private var tokenStore: any YouTubeTokenStoring
    private let now: @Sendable () -> Date
    private var authenticationSession: ASWebAuthenticationSession?
    private var tokenRefreshTask: Task<String, Error>?
    private var successorCreationTasks: [String: Task<YouTubeBroadcast, Error>] = [:]

    init(
        transport: any YouTubeAPITransport = URLSessionYouTubeAPITransport(),
        tokenStore: any YouTubeTokenStoring = SettingsYouTubeTokenStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        requestExecutor = YouTubeAPIRequestExecutor(transport: transport)
        self.tokenStore = tokenStore
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

    private func findStream(for streamKey: String, token: String) async throws -> YouTubeStream {
        let streamsURL = "\(YOUTUBE_API_BASE)/liveStreams?part=cdn,snippet&mine=true&maxResults=50"
        let streamItems: [YouTubeLiveStreamResource] = try await paginatedItems(
            url: streamsURL,
            token: token
        )
        return try YouTubeStreamDiscovery.findStream(
            in: streamItems,
            matchingStreamKey: streamKey
        )
    }

    private func listBroadcasts(boundTo streamId: String, token: String) async throws -> [YouTubeBroadcast] {
        let broadcastsURL = "\(YOUTUBE_API_BASE)/liveBroadcasts?part=snippet,contentDetails,status&mine=true&maxResults=50"
        let resources: [YouTubeBroadcastResource] = try await paginatedItems(
            url: broadcastsURL,
            token: token
        )

        return resources.compactMap { resource in
            guard resource.contentDetails?.boundStreamId == streamId else {
                return nil
            }
            return resource.broadcast
        }
    }

    private func successorScheduledStartTime(from broadcast: YouTubeBroadcast) -> String {
        if let scheduledStartTime = broadcast.scheduledStartTime,
           let scheduledDate = ISO8601DateFormatter().date(from: scheduledStartTime),
           scheduledDate > Date() {
            return scheduledStartTime
        }

        return ISO8601DateFormatter().string(from: Date().addingTimeInterval(5))
    }

    private func createSuccessorBroadcast(from broadcast: YouTubeBroadcast, streamId: String, token: String) async throws -> YouTubeBroadcast {
        let insertURL = "\(YOUTUBE_API_BASE)/liveBroadcasts?part=snippet,status,contentDetails"
        let body: [String: Any] = [
            "snippet": [
                "title": broadcast.title,
                "scheduledStartTime": successorScheduledStartTime(from: broadcast),
            ],
            "status": [
                "privacyStatus": broadcast.privacyStatus,
            ],
            "contentDetails": [
                "enableDvr": broadcast.enableDvr,
                "latencyPreference": broadcast.latencyPreference,
                "monitorStream": [
                    "enableMonitorStream": broadcast.enableMonitorStream,
                    "broadcastStreamDelayMs": broadcast.broadcastStreamDelayMs,
                ],
                "enableEmbed": broadcast.enableEmbed,
                "recordFromStart": broadcast.recordFromStart,
                "enableAutoStart": broadcast.enableAutoStart,
                "enableAutoStop": broadcast.enableAutoStop,
            ],
        ]

        let insertData = try JSONSerialization.data(withJSONObject: body)
        let insertResource: YouTubeBroadcastResource = try await apiPost(
            url: insertURL,
            token: token,
            jsonBody: insertData
        )
        guard let insertedBroadcast = insertResource.broadcast else {
            throw YouTubeError.invalidResponse
        }

        let bindURL = "\(YOUTUBE_API_BASE)/liveBroadcasts/bind?id=\(insertedBroadcast.id)&part=snippet,contentDetails,status&streamId=\(streamId)"
        let bindResource: YouTubeBroadcastResource = try await apiPost(
            url: bindURL,
            token: token,
            jsonBody: Data()
        )
        guard let boundBroadcast = bindResource.broadcast else {
            throw YouTubeError.invalidResponse
        }

        LOG("Created successor YouTube broadcast \(boundBroadcast.id) for stream \(streamId)", level: .info)
        return boundBroadcast
    }

    // MARK: - OAuth2 Authentication

    func signIn() async {
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

            try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)
            isSignedIn = true
            errorMessage = nil
            LOG("Signed in to YouTube successfully", level: .info)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            authenticationSession = nil
            LOG("YouTube sign-in cancelled by user", level: .debug)
        } catch {
            authenticationSession = nil
            errorMessage = error.localizedDescription
            LOG("YouTube sign-in failed: \(error.localizedDescription)", level: .error)
        }
    }

    @discardableResult
    func signOut() -> Bool {
        authenticationSession?.cancel()
        authenticationSession = nil
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        do {
            try tokenStore.clearAuthorization()
            isSignedIn = false
            errorMessage = nil
            LOG("Signed out of YouTube", level: .info)
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

        let tokenData = try await postForm(url: YOUTUBE_TOKEN_URL, body: body)
        try parseAndStoreTokens(from: tokenData)
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

        let tokenData = try await postForm(url: YOUTUBE_TOKEN_URL, body: body)
        try parseAndStoreTokens(from: tokenData)
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

    private func parseAndStoreTokens(from data: Data) throws {
        let response = try requestExecutor.decode(YouTubeTokenResponse.self, from: data)
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

    func findHLSIngestionEndpoint(forStreamKey streamKey: String) async throws -> YouTubeHLSEndpoint {
        beginLoading()
        defer { endLoading() }

        let token = try await getValidAccessToken()
        let stream = try await findStream(for: streamKey, token: token)
        return try YouTubeStreamDiscovery.hlsEndpoint(for: stream)
    }

    func findBroadcastForStreamKey(_ streamKey: String) async throws -> YouTubeBroadcast {
        beginLoading()
        defer { endLoading() }

        return try await selectedBroadcast(forStreamKey: streamKey).broadcast
    }

    func ensureCurrentBroadcastForStreamKey(_ streamKey: String) async throws -> YouTubeBroadcast {
        beginLoading()
        defer { endLoading() }

        let selection = try await selectedBroadcast(forStreamKey: streamKey)
        guard selection.broadcast.lifeCycleStatus == "complete" else {
            return selection.broadcast
        }
        if let existingTask = successorCreationTasks[selection.streamID] {
            return try await existingTask.value
        }
        let task = Task { @MainActor in
            try await self.createSuccessorBroadcast(
                from: selection.broadcast,
                streamId: selection.streamID,
                token: selection.token
            )
        }
        successorCreationTasks[selection.streamID] = task
        do {
            let successor = try await task.value
            successorCreationTasks[selection.streamID] = nil
            return successor
        } catch {
            successorCreationTasks[selection.streamID] = nil
            throw error
        }
    }

    private func selectedBroadcast(
        forStreamKey streamKey: String
    ) async throws -> (broadcast: YouTubeBroadcast, streamID: String, token: String) {

        let token = try await getValidAccessToken()
        let stream = try await findStream(for: streamKey, token: token)
        let matchingBroadcasts = try await listBroadcasts(boundTo: stream.id, token: token)

        guard let selectedBroadcast = YouTubeBroadcastDiscovery.selectCurrentOrMostRecent(
            from: matchingBroadcasts
        ) else {
            throw YouTubeError.noBroadcastFound
        }
        return (selectedBroadcast, stream.id, token)
    }

    // MARK: - YouTube API: Update Broadcast

    func updateBroadcast(id: String, title: String, privacyStatus: String, scheduledStartTime: String?, enableDvr: Bool, latencyPreference: String, enableMonitorStream: Bool, broadcastStreamDelayMs: Int, enableEmbed: Bool, recordFromStart: Bool, enableAutoStart: Bool, enableAutoStop: Bool) async throws {
        beginLoading()
        defer { endLoading() }

        let token = try await getValidAccessToken()
        let url = "\(YOUTUBE_API_BASE)/liveBroadcasts?part=snippet,status,contentDetails"

        var snippet: [String: Any] = ["title": title]
        if let scheduledStartTime {
            snippet["scheduledStartTime"] = scheduledStartTime
        }

        let body: [String: Any] = [
            "id": id,
            "snippet": snippet,
            "status": [
                "privacyStatus": privacyStatus,
            ],
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
            jsonBody: jsonData
        )
        guard resource.id == id else {
            throw YouTubeError.invalidResponse
        }

        LOG("Updated YouTube broadcast: \(title) (\(privacyStatus))", level: .info)
    }

    // MARK: - YouTube API: Broadcast Status (lightweight, 1 unit)

    func fetchBroadcastStatus(broadcastId: String) async throws -> String? {
        let token = try await getValidAccessToken()
        let url = "\(YOUTUBE_API_BASE)/liveBroadcasts?part=status&id=\(broadcastId)"
        let response: YouTubeListResponse<YouTubeBroadcastResource> = try await apiGet(
            url: url,
            token: token
        )
        return response.items.first?.status?.lifeCycleStatus
    }

    // MARK: - YouTube API: Transition (Stop)

    func stopBroadcast(id: String) async throws {
        beginLoading()
        defer { endLoading() }

        let token = try await getValidAccessToken()
        let url = "\(YOUTUBE_API_BASE)/liveBroadcasts/transition?broadcastStatus=complete&id=\(id)&part=status"
        let resource: YouTubeBroadcastResource = try await apiPost(
            url: url,
            token: token,
            jsonBody: Data()
        )
        guard resource.id == id else {
            throw YouTubeError.invalidResponse
        }

        LOG("Stopped YouTube broadcast \(id)", level: .info)
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
        _ = try await authenticatedData(for: request, fallbackToken: token)

        LOG("Uploaded thumbnail for broadcast \(videoId)", level: .info)
    }

    // MARK: - YouTube API: Playlists

    func listPlaylists() async throws -> [YouTubePlaylist] {
        beginLoading()
        defer { endLoading() }

        let token = try await getValidAccessToken()
        let url = "\(YOUTUBE_API_BASE)/playlists?part=snippet&mine=true&maxResults=50"
        let items: [YouTubePlaylistResource] = try await paginatedItems(
            url: url,
            token: token
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
            token: token
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
            jsonBody: jsonData
        )
        guard inserted.id != nil else {
            throw YouTubeError.invalidResponse
        }

        LOG("Added broadcast to playlist \(playlistId)", level: .info)
    }

    // MARK: - HTTP Helpers

    private func apiGet<Response: Decodable & Sendable>(
        url: String,
        token: String
    ) async throws -> Response {
        guard let requestURL = URL(string: url) else {
            throw YouTubeError.invalidResponse
        }
        var request = URLRequest(url: requestURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let data = try await authenticatedData(for: request, fallbackToken: token)
        return try requestExecutor.decode(Response.self, from: data)
    }

    private func paginatedItems<Item: Decodable & Sendable>(
        url: String,
        token: String
    ) async throws -> [Item] {
        guard let baseComponents = URLComponents(string: url) else {
            throw YouTubeError.invalidResponse
        }

        var items: [Item] = []
        var pageToken: String?
        var seenPageTokens: Set<String> = []

        repeat {
            var components = baseComponents
            if let pageToken {
                components.queryItems = (components.queryItems ?? []) + [
                    URLQueryItem(name: "pageToken", value: pageToken),
                ]
            }
            guard let pageURL = components.url else {
                throw YouTubeError.invalidResponse
            }

            let page: YouTubeListResponse<Item> = try await apiGet(
                url: pageURL.absoluteString,
                token: token
            )
            items.append(contentsOf: page.items)

            guard let nextPageToken = page.nextPageToken,
                  !nextPageToken.isEmpty else {
                pageToken = nil
                continue
            }
            guard seenPageTokens.insert(nextPageToken).inserted else {
                throw YouTubeError.invalidResponse
            }
            pageToken = nextPageToken
        } while pageToken != nil

        return items
    }

    private func apiPut<Response: Decodable & Sendable>(
        url: String,
        token: String,
        jsonBody: Data
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
        let data = try await authenticatedData(for: request, fallbackToken: token)
        return try requestExecutor.decode(Response.self, from: data)
    }

    private func apiPost<Response: Decodable & Sendable>(
        url: String,
        token: String,
        jsonBody: Data
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
        let data = try await authenticatedData(for: request, fallbackToken: token)
        return try requestExecutor.decode(Response.self, from: data)
    }

    private func postForm(url: String, body: [String: String]) async throws -> Data {
        guard let requestURL = URL(string: url) else {
            throw YouTubeError.invalidResponse
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoder.encode(body)
        request.timeoutInterval = 30
        return try await requestExecutor.data(for: request)
    }

    private func authenticatedData(
        for originalRequest: URLRequest,
        fallbackToken: String
    ) async throws -> Data {
        var request = originalRequest
        var token = fallbackToken

        for attempt in 0...1 {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            do {
                return try await requestExecutor.data(for: request)
            } catch YouTubeError.apiError(let statusCode, _) where statusCode == 401 && attempt == 0 {
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
