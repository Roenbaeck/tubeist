//
//  YouTubeAPITransport.swift
//  Tubeist
//

import Foundation

enum YouTubeError: LocalizedError, Equatable {
    case notSignedIn
    case noClientId
    case authFailed(String)
    case apiError(Int, String)
    case noBroadcastFound
    case noStreamFound
    case broadcastNotReady(String)
    case incompatibleIngestionType(String)
    case invalidIngestionAddress
    case thumbnailTooLarge
    case invalidResponse
    case tokenRefreshFailed

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Not signed in to YouTube"
        case .noClientId: "YouTube Client ID not configured"
        case .authFailed(let message): "Authentication failed: \(message)"
        case .apiError(let code, let message): "YouTube API error (\(code)): \(message)"
        case .noBroadcastFound: "No active or upcoming broadcast. Tubeist will create one when you start streaming."
        case .noStreamFound: "No stream found matching this key"
        case .broadcastNotReady(let status):
            "The YouTube broadcast is \(status) and cannot start. If the previous stream is still finishing, wait and try again; otherwise review its YouTube setup."
        case .incompatibleIngestionType(let type):
            "This YouTube stream key uses \(type.uppercased()) ingestion. YouTube streaming requires an HLS stream key."
        case .invalidIngestionAddress: "YouTube did not return a valid HLS ingestion address"
        case .thumbnailTooLarge: "The selected thumbnail cannot be compressed below YouTube's 2 MB limit"
        case .invalidResponse: "Invalid response from YouTube API"
        case .tokenRefreshFailed: "Failed to refresh access token"
        }
    }
}

struct YouTubeAPIResponse: Sendable, Equatable {
    let data: Data
    let statusCode: Int
    var requestID: String? = nil
}

/// Fixed operation names keep URLs, query values and credentials out of diagnostics.
enum YouTubeAPIOperation: String, Sendable {
    case unspecified = "API request"
    case exchangeCode = "oauth.exchangeCode"
    case refreshToken = "oauth.refreshToken"
    case channels = "channels.list"
    case streams = "liveStreams.list"
    case broadcasts = "liveBroadcasts.list"
    case broadcastStatus = "liveBroadcasts.list (status)"
    case createStream = "liveStreams.insert"
    case createBroadcast = "liveBroadcasts.insert"
    case bindBroadcast = "liveBroadcasts.bind"
    case updateBroadcast = "liveBroadcasts.update"
    case transitionBroadcast = "liveBroadcasts.transition"
    case thumbnail = "thumbnails.set"
    case playlists = "playlists.list"
    case playlistItems = "playlistItems.list"
    case insertPlaylistItem = "playlistItems.insert"

    var successLevel: LogLevel { .debug }
    var failureLevel: LogLevel { self == .channels ? .warning : .error }
}

struct YouTubeDiagnostics: Sendable {
    var log: @Sendable (String, LogLevel) -> Void = { LOG($0, level: $1) }

    /// Sanitize before truncating so a partial credential cannot escape redaction.
    static func text(_ value: String, secrets: [String] = []) -> String {
        var result = value
        for secret in secrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: secret, with: "[redacted]")
        }
        for pattern in [
            #"(?i)https?://[^\s<>\"']+"#,
            #"(?i)Bearer\s+[^\s,;\"']+"#,
            #"(?i)(?:access_token|refresh_token|code_verifier|stream_key|streamName|cid|code)\s*[=:]\s*[^\s,;&\"']+"#,
        ] {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return String(result.components(separatedBy: .controlCharacters.union(.newlines)).joined(separator: " ").prefix(1_000))
    }

    static func secrets(in request: URLRequest) -> [String] {
        let sensitiveNames: Set<String> = ["key", "cid", "code", "state", "access_token", "refresh_token", "code_verifier", "pageToken"]
        var values = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.filter { sensitiveNames.contains($0.name) }.compactMap(\.value) ?? []
        if let authorization = request.value(forHTTPHeaderField: "Authorization") {
            values.append(authorization)
            if authorization.hasPrefix("Bearer ") { values.append(String(authorization.dropFirst(7))) }
        }
        if request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded",
           let data = request.httpBody, let body = String(data: data, encoding: .utf8),
           let form = URLComponents(string: "https://redaction.invalid/?" + body.replacingOccurrences(of: "+", with: "%20")) {
            values += form.queryItems?.compactMap(\.value) ?? []
        }
        return values
    }

    static func failure(_ error: Error) -> String {
        let nsError = error as NSError
        if error is CancellationError || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
            return "cancelled"
        }
        // localizedDescription/userInfo can contain failing URLs and response bodies.
        if let error = error as? YouTubeError {
            switch error {
            case .apiError(let code, _): return "HTTP \(code)"
            case .notSignedIn: return "no saved authorization"
            case .noStreamFound: return "no matching stream key in the authorized account"
            case .noBroadcastFound: return "no broadcast bound to the matching stream"
            case .invalidResponse: return "invalid response structure"
            case .tokenRefreshFailed: return "token refresh failed"
            default: return "YouTube operation failed"
            }
        }
        let domain = nsError.domain == NSURLErrorDomain ? "NSURLErrorDomain" : "transport/storage error"
        return "\(domain) code=\(nsError.code)"
    }
}

protocol YouTubeAPITransport: Sendable {
    func response(for request: URLRequest) async throws -> YouTubeAPIResponse
}

struct URLSessionYouTubeAPITransport: YouTubeAPITransport, Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func response(for request: URLRequest) async throws -> YouTubeAPIResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw YouTubeError.invalidResponse
        }
        return YouTubeAPIResponse(
            data: data, statusCode: response.statusCode,
            requestID: response.value(forHTTPHeaderField: "x-goog-request-id")
                ?? response.value(forHTTPHeaderField: "x-request-id")
        )
    }
}

struct YouTubeAPIRequestExecutor: Sendable {
    let transport: any YouTubeAPITransport
    let diagnostics: YouTubeDiagnostics
    private let decoder = JSONDecoder()

    init(transport: any YouTubeAPITransport = URLSessionYouTubeAPITransport(),
         diagnostics: YouTubeDiagnostics = YouTubeDiagnostics()) {
        self.transport = transport
        self.diagnostics = diagnostics
    }

    func data(for request: URLRequest, operation: YouTubeAPIOperation = .unspecified) async throws -> Data {
        try Task.checkCancellation()
        let label = "YouTube [\(UUID().uuidString.prefix(8))] \(operation.rawValue)"
        guard request.url?.scheme?.lowercased() == "https" else {
            diagnostics.log("\(label): rejected non-HTTPS request", .error)
            throw YouTubeError.invalidResponse
        }
        diagnostics.log("\(label): started", operation.successLevel)
        let started = ProcessInfo.processInfo.systemUptime
        let response: YouTubeAPIResponse
        do {
            response = try await transport.response(for: request)
        } catch {
            let failure = YouTubeDiagnostics.failure(error)
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            diagnostics.log("\(label): \(failure) after \(elapsed) ms", failure == "cancelled" ? .debug : operation.failureLevel)
            throw error
        }
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        let secrets = YouTubeDiagnostics.secrets(in: request)
        let serverID = response.requestID.map { "; Google request ID=\(YouTubeDiagnostics.text($0, secrets: secrets))" } ?? ""
        let result = "\(label): HTTP \(response.statusCode) in \(elapsed) ms\(serverID)"
        guard (200...299).contains(response.statusCode) else {
            diagnostics.log("\(result); \(Self.errorDetails(from: response.data, secrets: secrets))", operation.failureLevel)
            throw YouTubeError.apiError(
                response.statusCode,
                YouTubeDiagnostics.text(Self.errorMessage(from: response.data), secrets: secrets)
            )
        }
        diagnostics.log(result, operation.successLevel)
        return response.data
    }

    func decode<Response: Decodable & Sendable>(
        _ responseType: Response.Type,
        for request: URLRequest,
        operation: YouTubeAPIOperation = .unspecified
    ) async throws -> Response {
        let data = try await data(for: request, operation: operation)
        return try decode(responseType, from: data, operation: operation)
    }

    func decode<Response: Decodable & Sendable>(
        _ responseType: Response.Type,
        from data: Data,
        operation: YouTubeAPIOperation = .unspecified
    ) throws -> Response {
        do {
            return try decoder.decode(responseType, from: data)
        } catch {
            diagnostics.log("YouTube \(operation.rawValue): invalid response structure (\(data.count) bytes)", operation.failureLevel)
            throw YouTubeError.invalidResponse
        }
    }

    private static func errorDetails(from data: Data, secrets: [String]) -> String {
        // Only structured error identifiers; never dump messages, payloads or headers.
        if let envelope = try? JSONDecoder().decode(YouTubeAPIErrorEnvelope.self, from: data) {
            var details: [String] = []
            if let status = envelope.error.status { details.append("status=\(status)") }
            for item in (envelope.error.errors ?? []).prefix(5) {
                if let domain = item.domain { details.append("domain=\(domain)") }
                if let reason = item.reason { details.append("reason=\(reason)") }
            }
            return YouTubeDiagnostics.text(details.isEmpty ? "no structured error reason" : details.joined(separator: "; "), secrets: secrets)
        }
        if let envelope = try? JSONDecoder().decode(OAuthErrorEnvelope.self, from: data) {
            return YouTubeDiagnostics.text("OAuth reason=\(envelope.error)", secrets: secrets)
        }
        return "unstructured error response (\(data.count) bytes)"
    }

    private static func errorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(YouTubeAPIErrorEnvelope.self, from: data),
           let message = envelope.error.message,
           !message.isEmpty {
            return message
        }
        if let envelope = try? JSONDecoder().decode(OAuthErrorEnvelope.self, from: data) {
            let message = envelope.errorDescription ?? envelope.error
            if !message.isEmpty {
                return message
            }
        }
        return "The request was rejected"
    }
}

private struct YouTubeAPIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        struct Detail: Decodable {
            let domain: String?
            let reason: String?
        }
        let message: String?
        let status: String?
        let errors: [Detail]?
    }

    let error: APIError
}

private struct OAuthErrorEnvelope: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

enum FormURLEncoder {
    static func encode(_ values: [String: String]) -> Data {
        let body = values.keys.sorted().map { key in
            "\(escape(key))=\(escape(values[key] ?? ""))"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func escape(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39,
                 0x2D, 0x2E, 0x5F, 0x7E:
                String(UnicodeScalar(byte))
            default:
                String(format: "%%%02X", byte)
            }
        }.joined()
    }
}
