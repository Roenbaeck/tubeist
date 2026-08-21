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
        case .noBroadcastFound: "No broadcast found for this stream key"
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
        return YouTubeAPIResponse(data: data, statusCode: response.statusCode)
    }
}

struct YouTubeAPIRequestExecutor: Sendable {
    let transport: any YouTubeAPITransport
    private let decoder = JSONDecoder()

    init(transport: any YouTubeAPITransport = URLSessionYouTubeAPITransport()) {
        self.transport = transport
    }

    func data(for request: URLRequest) async throws -> Data {
        guard request.url?.scheme?.lowercased() == "https" else {
            throw YouTubeError.invalidResponse
        }
        let response = try await transport.response(for: request)
        guard (200...299).contains(response.statusCode) else {
            throw YouTubeError.apiError(
                response.statusCode,
                Self.errorMessage(from: response.data)
            )
        }
        return response.data
    }

    func decode<Response: Decodable & Sendable>(
        _ responseType: Response.Type,
        for request: URLRequest
    ) async throws -> Response {
        let data = try await data(for: request)
        return try decode(responseType, from: data)
    }

    func decode<Response: Decodable & Sendable>(
        _ responseType: Response.Type,
        from data: Data
    ) throws -> Response {
        do {
            return try decoder.decode(responseType, from: data)
        } catch {
            throw YouTubeError.invalidResponse
        }
    }

    private static func errorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(YouTubeAPIErrorEnvelope.self, from: data),
           let message = envelope.error.message,
           !message.isEmpty {
            return String(message.prefix(1_000))
        }
        if let envelope = try? JSONDecoder().decode(OAuthErrorEnvelope.self, from: data) {
            let message = envelope.errorDescription ?? envelope.error
            if !message.isEmpty {
                return String(message.prefix(1_000))
            }
        }
        return "The request was rejected"
    }
}

private struct YouTubeAPIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String?
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
