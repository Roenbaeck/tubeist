//
//  YouTubeService.swift
//  Tubeist
//
//  YouTube Data API v3 integration for managing stream settings.
//  Handles OAuth2 authentication and broadcast/playlist management.
//

import Foundation
import AuthenticationServices
import CryptoKit

// MARK: - Models

struct YouTubeBroadcast: Identifiable {
    let id: String
    var title: String
    var privacyStatus: String
    let boundStreamId: String?
    let scheduledStartTime: String?
    var lifeCycleStatus: String?

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

struct YouTubePlaylist: Identifiable {
    let id: String
    let title: String
}

enum YouTubeError: LocalizedError {
    case notSignedIn
    case noClientId
    case authFailed(String)
    case apiError(Int, String)
    case noBroadcastFound
    case noStreamFound
    case invalidResponse
    case tokenRefreshFailed

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in to YouTube"
        case .noClientId: return "YouTube Client ID not configured"
        case .authFailed(let msg): return "Authentication failed: \(msg)"
        case .apiError(let code, let msg): return "YouTube API error (\(code)): \(msg)"
        case .noBroadcastFound: return "No broadcast found for this stream key"
        case .noStreamFound: return "No stream found matching this key"
        case .invalidResponse: return "Invalid response from YouTube API"
        case .tokenRefreshFailed: return "Failed to refresh access token"
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

    private static func broadcastStatusPriority(_ status: String?) -> Int {
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

    init() {
        isSignedIn = Settings.youtubeRefreshToken != nil
    }

    // MARK: - OAuth2 Authentication

    func signIn() async {
        guard YOUTUBE_CLIENT_ID != "YOUR_GOOGLE_OAUTH2_CLIENT_ID" else {
            errorMessage = "YouTube Client ID not configured in Constants.swift"
            LOG("YouTube Client ID not configured", level: .error)
            return
        }

        let codeVerifier = generateCodeVerifier()
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
        ]

        guard let authURL = components.url else {
            errorMessage = "Failed to construct auth URL"
            return
        }

        do {
            let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: YOUTUBE_REDIRECT_SCHEME
                ) { url, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let url = url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: YouTubeError.authFailed("No URL returned"))
                    }
                }
                session.prefersEphemeralWebBrowserSession = false
                session.presentationContextProvider = ASWebAuthPresentationContext.shared
                session.start()
            }

            guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else {
                errorMessage = "No authorization code received"
                return
            }

            try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)
            isSignedIn = true
            errorMessage = nil
            LOG("Signed in to YouTube successfully", level: .info)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            LOG("YouTube sign-in cancelled by user", level: .debug)
        } catch {
            errorMessage = error.localizedDescription
            LOG("YouTube sign-in failed: \(error.localizedDescription)", level: .error)
        }
    }

    func signOut() {
        Settings.youtubeAccessToken = nil
        Settings.youtubeRefreshToken = nil
        Settings.youtubeTokenExpiry = nil
        isSignedIn = false
        LOG("Signed out of YouTube", level: .info)
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

    private func refreshAccessToken() async throws {
        guard let refreshToken = Settings.youtubeRefreshToken else {
            throw YouTubeError.notSignedIn
        }

        let body: [String: String] = [
            "client_id": YOUTUBE_CLIENT_ID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]

        let tokenData = try await postForm(url: YOUTUBE_TOKEN_URL, body: body)
        try parseAndStoreTokens(from: tokenData)
    }

    private func parseAndStoreTokens(from data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeError.invalidResponse
        }
        if let error = json["error"] as? String {
            let description = json["error_description"] as? String ?? error
            throw YouTubeError.authFailed(description)
        }
        guard let accessToken = json["access_token"] as? String else {
            throw YouTubeError.invalidResponse
        }
        let expiresIn = json["expires_in"] as? Int ?? 3600

        Settings.youtubeAccessToken = accessToken
        Settings.youtubeTokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))

        // Refresh token is only returned on initial authorization, not on refresh
        if let refreshToken = json["refresh_token"] as? String {
            Settings.youtubeRefreshToken = refreshToken
        }
    }

    private func getValidAccessToken() async throws -> String {
        if let token = Settings.youtubeAccessToken,
           let expiry = Settings.youtubeTokenExpiry,
           Date() < expiry {
            return token
        }
        try await refreshAccessToken()
        guard let token = Settings.youtubeAccessToken else {
            throw YouTubeError.tokenRefreshFailed
        }
        return token
    }

    // MARK: - YouTube API: Streams

    func findBroadcastForStreamKey(_ streamKey: String) async throws -> YouTubeBroadcast {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let token = try await getValidAccessToken()

        // Step 1: Find the stream matching the key
        let streamsURL = "\(YOUTUBE_API_BASE)/liveStreams?part=cdn,snippet&mine=true&maxResults=50"
        let streamsData = try await apiGet(url: streamsURL, token: token)
        guard let streamsJson = try JSONSerialization.jsonObject(with: streamsData) as? [String: Any],
              let items = streamsJson["items"] as? [[String: Any]] else {
            throw YouTubeError.invalidResponse
        }

        var matchedStreamId: String?
        for item in items {
            if let cdn = item["cdn"] as? [String: Any],
               let ingestionInfo = cdn["ingestionInfo"] as? [String: Any],
               let streamName = ingestionInfo["streamName"] as? String,
               streamName == streamKey,
               let id = item["id"] as? String {
                matchedStreamId = id
                break
            }
        }

        guard let streamId = matchedStreamId else {
            throw YouTubeError.noStreamFound
        }

        // Step 2: Find the broadcast bound to this stream
        let broadcastsURL = "\(YOUTUBE_API_BASE)/liveBroadcasts?part=snippet,contentDetails,status&mine=true&maxResults=50"
        let broadcastsData = try await apiGet(url: broadcastsURL, token: token)
        guard let broadcastsJson = try JSONSerialization.jsonObject(with: broadcastsData) as? [String: Any],
              let broadcasts = broadcastsJson["items"] as? [[String: Any]] else {
            throw YouTubeError.invalidResponse
        }

        let matchingBroadcasts: [YouTubeBroadcast] = broadcasts.compactMap { broadcast in
            guard let contentDetails = broadcast["contentDetails"] as? [String: Any],
                  let boundStreamId = contentDetails["boundStreamId"] as? String,
                  boundStreamId == streamId,
                  let id = broadcast["id"] as? String,
                  let snippet = broadcast["snippet"] as? [String: Any] else {
                return nil
            }

            let title = snippet["title"] as? String ?? ""
            let scheduledStartTime = snippet["scheduledStartTime"] as? String
            let status = broadcast["status"] as? [String: Any]
            let privacyStatus = status?["privacyStatus"] as? String ?? "public"
            let lifeCycleStatus = status?["lifeCycleStatus"] as? String

            return YouTubeBroadcast(
                id: id,
                title: title,
                privacyStatus: privacyStatus,
                boundStreamId: boundStreamId,
                scheduledStartTime: scheduledStartTime,
                lifeCycleStatus: lifeCycleStatus
            )
        }

        guard let selectedBroadcast = matchingBroadcasts.sorted(by: { lhs, rhs in
            let lhsPriority = Self.broadcastStatusPriority(lhs.lifeCycleStatus)
            let rhsPriority = Self.broadcastStatusPriority(rhs.lifeCycleStatus)
            if lhsPriority != rhsPriority {
                return lhsPriority > rhsPriority
            }

            return (lhs.scheduledStartTime ?? "") > (rhs.scheduledStartTime ?? "")
        }).first else {
            throw YouTubeError.noBroadcastFound
        }

        return selectedBroadcast
    }

    // MARK: - YouTube API: Update Broadcast

    func updateBroadcast(id: String, title: String, privacyStatus: String, scheduledStartTime: String?) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let token = try await getValidAccessToken()
        let url = "\(YOUTUBE_API_BASE)/liveBroadcasts?part=snippet,status"

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
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let responseData = try await apiPut(url: url, token: token, jsonBody: jsonData)

        if let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let code = error["code"] as? Int,
           let message = error["message"] as? String {
            throw YouTubeError.apiError(code, message)
        }

        LOG("Updated YouTube broadcast: \(title) (\(privacyStatus))", level: .info)
    }

    // MARK: - YouTube API: Broadcast Status (lightweight, 1 unit)

    func fetchBroadcastStatus(broadcastId: String) async throws -> String? {
        let token = try await getValidAccessToken()
        let url = "\(YOUTUBE_API_BASE)/liveBroadcasts?part=status&id=\(broadcastId)"
        let data = try await apiGet(url: url, token: token)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]],
              let first = items.first,
              let status = first["status"] as? [String: Any],
              let lifeCycleStatus = status["lifeCycleStatus"] as? String else {
            return nil
        }
        return lifeCycleStatus
    }

    // MARK: - YouTube API: Transition (Stop)

    func stopBroadcast(id: String) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let token = try await getValidAccessToken()
        let url = "\(YOUTUBE_API_BASE)/liveBroadcasts/transition?broadcastStatus=complete&id=\(id)&part=status"
        let responseData = try await apiPost(url: url, token: token, jsonBody: Data())

        if let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let code = error["code"] as? Int,
           let message = error["message"] as? String {
            throw YouTubeError.apiError(code, message)
        }

        LOG("Stopped YouTube broadcast \(id)", level: .info)
    }

    // MARK: - YouTube API: Thumbnail

    func uploadThumbnail(videoId: String, imageData: Data) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

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

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        LOG("Thumbnail upload response: \(httpResponse?.statusCode ?? 0)", level: .debug)

        if let httpResponse, !(200...299).contains(httpResponse.statusCode) {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw YouTubeError.apiError(httpResponse.statusCode, errorMsg)
        }

        // Check for API-level errors in the JSON response
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let code = error["code"] as? Int,
           let message = error["message"] as? String {
            throw YouTubeError.apiError(code, message)
        }

        LOG("Uploaded thumbnail for broadcast \(videoId)", level: .info)
    }

    // MARK: - YouTube API: Playlists

    func listPlaylists() async throws -> [YouTubePlaylist] {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let token = try await getValidAccessToken()
        let url = "\(YOUTUBE_API_BASE)/playlists?part=snippet&mine=true&maxResults=50"
        let data = try await apiGet(url: url, token: token)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            throw YouTubeError.invalidResponse
        }

        return items.compactMap { item in
            guard let id = item["id"] as? String,
                  let snippet = item["snippet"] as? [String: Any],
                  let title = snippet["title"] as? String else {
                return nil
            }
            return YouTubePlaylist(id: id, title: title)
        }
    }

    func addToPlaylist(playlistId: String, videoId: String) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let token = try await getValidAccessToken()
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
        let responseData = try await apiPost(url: url, token: token, jsonBody: jsonData)

        if let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let code = error["code"] as? Int,
               let message = error["message"] as? String {
                throw YouTubeError.apiError(code, message)
            }
        }

        LOG("Added broadcast to playlist \(playlistId)", level: .info)
    }

    // MARK: - HTTP Helpers

    private func apiGet(url: String, token: String) async throws -> Data {
        guard let requestURL = URL(string: url) else {
            throw YouTubeError.invalidResponse
        }
        var request = URLRequest(url: requestURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw YouTubeError.apiError(httpResponse.statusCode, errorMsg)
        }
        return data
    }

    private func apiPut(url: String, token: String, jsonBody: Data) async throws -> Data {
        guard let requestURL = URL(string: url) else {
            throw YouTubeError.invalidResponse
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonBody
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private func apiPost(url: String, token: String, jsonBody: Data) async throws -> Data {
        guard let requestURL = URL(string: url) else {
            throw YouTubeError.invalidResponse
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonBody
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private func postForm(url: String, body: [String: String]) async throws -> Data {
        guard let requestURL = URL(string: url) else {
            throw YouTubeError.invalidResponse
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let bodyString = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
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
        var quality: CGFloat = 0.9
        while quality > 0.1 {
            if let data = jpegData(compressionQuality: quality), data.count <= maxBytes {
                return data
            }
            quality -= 0.1
        }
        return jpegData(compressionQuality: 0.1)
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
