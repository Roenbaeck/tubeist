//
//  YouTubeHLSUploader.swift
//  Tubeist
//

import Foundation

struct YouTubeHLSEndpoint: Sendable, Equatable {
    private let value: URL

    init(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              url.absoluteString.hasSuffix("file=") else {
            throw YouTubeHLSUploadError.invalidEndpoint
        }
        self.value = url
    }

    static func manualPrimary(streamKey: String) throws -> YouTubeHLSEndpoint {
        guard !streamKey.isEmpty,
              streamKey.utf8.allSatisfy({
                  ($0 >= 0x30 && $0 <= 0x39) ||
                      ($0 >= 0x41 && $0 <= 0x5a) ||
                      ($0 >= 0x61 && $0 <= 0x7a) ||
                      $0 == 0x2d
              }),
              let url = URL(string: "https://a.upload.youtube.com/http_upload_hls?cid=\(streamKey)&copy=0&file=") else {
            throw YouTubeHLSUploadError.invalidEndpoint
        }
        return try YouTubeHLSEndpoint(url)
    }

    func requestURL(filename: String) throws -> URL {
        guard !filename.isEmpty,
              filename.utf8.allSatisfy({
                  ($0 >= 0x30 && $0 <= 0x39) ||
                      ($0 >= 0x41 && $0 <= 0x5a) ||
                      ($0 >= 0x61 && $0 <= 0x7a) ||
                      $0 == 0x2d || $0 == 0x2e || $0 == 0x5f
              }),
              let result = URL(string: value.absoluteString + filename) else {
            throw YouTubeHLSUploadError.invalidFilename
        }
        return result
    }
}

struct YouTubeHLSHTTPResponse: Sendable, Equatable {
    let statusCode: Int
    let body: Data

    init(statusCode: Int, body: Data = Data()) {
        self.statusCode = statusCode
        self.body = body
    }
}

protocol YouTubeHLSHTTPTransport: Sendable {
    func send(_ request: URLRequest, body: Data) async throws -> YouTubeHLSHTTPResponse
    func invalidate() async
}

actor URLSessionYouTubeHLSHTTPTransport: YouTubeHLSHTTPTransport {
    private let session: URLSession

    init() {
        self.session = Self.makeSession(
            requestTimeout: 10,
            resourceTimeout: 30,
            delegate: nil
        )
    }

    init(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        delegate: (any URLSessionDelegate & Sendable)
    ) {
        self.session = Self.makeSession(
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout,
            delegate: delegate
        )
    }

    private nonisolated static func makeSession(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        delegate: (any URLSessionDelegate)?
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.networkServiceType = .video
        return URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    func send(_ request: URLRequest, body: Data) async throws -> YouTubeHLSHTTPResponse {
        var request = request
        request.httpBody = body
        let (responseBody, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeHLSUploadError.invalidResponse
        }
        return YouTubeHLSHTTPResponse(statusCode: httpResponse.statusCode, body: responseBody)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }
}

struct YouTubeHLSRetryPolicy: Sendable, Equatable {
    let maximumAttempts: Int
    let initialDelay: TimeInterval
    let maximumDelay: TimeInterval
    let jitterFraction: Double

    static let `default` = YouTubeHLSRetryPolicy(
        maximumAttempts: 5,
        initialDelay: 0.5,
        maximumDelay: 8,
        jitterFraction: 0.2
    )
}

enum YouTubeHLSUploadError: LocalizedError, Equatable, CustomStringConvertible {
    case invalidEndpoint
    case invalidFilename
    case invalidResponse
    case rejected(statusCode: Int)
    case retriesExhausted
    case stopped

    var description: String {
        switch self {
        case .invalidEndpoint: "The YouTube HLS ingestion endpoint is invalid"
        case .invalidFilename: "The HLS filename contains unsupported characters"
        case .invalidResponse: "YouTube returned a non-HTTP response"
        case .rejected(let statusCode): "YouTube rejected the HLS upload (HTTP \(statusCode))"
        case .retriesExhausted: "The YouTube HLS upload retry limit was reached"
        case .stopped: "The YouTube HLS uploader has stopped"
        }
    }

    var errorDescription: String? { description }
}

struct YouTubeHLSUploadReceipt: Sendable, Equatable {
    let sequence: Int
    let segmentFilename: String
    let playlistFilename: String
}

struct YouTubeHLSUploaderDiagnostics: Sendable, Equatable {
    let retryCount: Int
    let lastHTTPStatus: Int?
}

actor YouTubeHLSUploader {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let endpoint: YouTubeHLSEndpoint
    private let userAgent: String
    private let transport: any YouTubeHLSHTTPTransport
    private let retryPolicy: YouTubeHLSRetryPolicy
    private let sleeper: Sleeper
    private var playlist: HLSMediaPlaylist
    private var stopped = false
    private var uploadInProgress = false
    private var uploadTurnWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastMegabitsPerSecond = 0
    private var lastUtilization = 0
    private var lastRetryCount = 0
    private var lastHTTPStatus: Int?

    init(
        endpoint: YouTubeHLSEndpoint,
        sessionIdentifier: String,
        userAgent: String,
        transport: any YouTubeHLSHTTPTransport = URLSessionYouTubeHLSHTTPTransport(),
        retryPolicy: YouTubeHLSRetryPolicy = .default,
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) throws {
        guard retryPolicy.maximumAttempts > 0,
              retryPolicy.initialDelay >= 0,
              retryPolicy.maximumDelay >= retryPolicy.initialDelay,
              (0...1).contains(retryPolicy.jitterFraction) else {
            throw YouTubeHLSUploadError.invalidResponse
        }
        self.endpoint = endpoint
        self.userAgent = userAgent
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.sleeper = sleeper
        self.playlist = try HLSMediaPlaylist(sessionIdentifier: sessionIdentifier)
    }

    var queuedDuration: Double {
        playlist.queuedDuration
    }

    var outstandingCount: Int {
        playlist.outstandingCount
    }

    var performance: (megabitsPerSecond: Int, utilization: Int) {
        (lastMegabitsPerSecond, lastUtilization)
    }

    var diagnostics: YouTubeHLSUploaderDiagnostics {
        YouTubeHLSUploaderDiagnostics(
            retryCount: lastRetryCount,
            lastHTTPStatus: lastHTTPStatus
        )
    }

    func upload(
        segment: Data,
        duration: Double,
        discontinuity: Bool = false
    ) async throws -> YouTubeHLSUploadReceipt {
        await acquireUploadTurn()
        defer { releaseUploadTurn() }
        do {
            guard !stopped, !Task.isCancelled else {
                throw YouTubeHLSUploadError.stopped
            }
            lastRetryCount = 0
            lastHTTPStatus = nil
            let uploadStart = Date()
            let entry = try playlist.append(duration: duration, discontinuity: discontinuity)
            let playlistBody = Data(playlist.render().utf8)
            let playlistRetries = try await send(
                filename: playlist.playlistFilename,
                contentType: "application/vnd.apple.mpegurl",
                body: playlistBody,
                priorRetryCount: 0
            )
            let segmentRetries = try await send(
                filename: entry.filename,
                contentType: "video/mp2t",
                body: segment,
                priorRetryCount: playlistRetries
            )
            lastRetryCount = playlistRetries + segmentRetries
            try playlist.acknowledge(sequence: entry.sequence)
            let elapsed = max(Date().timeIntervalSince(uploadStart), 0.001)
            lastMegabitsPerSecond = Int((Double(segment.count) * 8 / 1_000_000) / elapsed)
            lastUtilization = Int((elapsed / duration) * 100)
            return YouTubeHLSUploadReceipt(
                sequence: entry.sequence,
                segmentFilename: entry.filename,
                playlistFilename: playlist.playlistFilename
            )
        } catch {
            if !stopped {
                stopped = true
                await transport.invalidate()
            }
            if error is CancellationError {
                throw YouTubeHLSUploadError.stopped
            }
            throw error
        }
    }

    func stop() async {
        stopped = true
        await transport.invalidate()
    }

    private func send(
        filename: String,
        contentType: String,
        body: Data,
        priorRetryCount: Int
    ) async throws -> Int {
        let url = try endpoint.requestURL(filename: filename)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        var attempt = 1
        while true {
            guard !stopped, !Task.isCancelled else {
                throw YouTubeHLSUploadError.stopped
            }
            lastRetryCount = priorRetryCount + attempt - 1
            do {
                let response = try await transport.send(request, body: body)
                guard !stopped, !Task.isCancelled else {
                    throw YouTubeHLSUploadError.stopped
                }
                lastHTTPStatus = response.statusCode
                if response.statusCode == 200 || response.statusCode == 202 {
                    return attempt - 1
                }
                if (400...499).contains(response.statusCode) {
                    throw YouTubeHLSUploadError.rejected(statusCode: response.statusCode)
                }
            } catch let error as YouTubeHLSUploadError {
                switch error {
                case .rejected, .stopped:
                    throw error
                default:
                    break
                }
            } catch {
                lastHTTPStatus = nil
                // Network errors are transient and use the same bounded policy as 5xx.
            }

            guard !stopped, !Task.isCancelled else {
                throw YouTubeHLSUploadError.stopped
            }
            guard attempt < retryPolicy.maximumAttempts else {
                throw YouTubeHLSUploadError.retriesExhausted
            }
            let exponent = pow(2, Double(attempt - 1))
            let baseDelay = min(retryPolicy.maximumDelay, retryPolicy.initialDelay * exponent)
            let jitter = retryPolicy.jitterFraction == 0
                ? 1
                : Double.random(in: (1 - retryPolicy.jitterFraction)...(1 + retryPolicy.jitterFraction))
            try await sleeper(.seconds(baseDelay * jitter))
            attempt += 1
        }
    }

    private func acquireUploadTurn() async {
        if !uploadInProgress {
            uploadInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            uploadTurnWaiters.append(continuation)
        }
    }

    private func releaseUploadTurn() {
        guard !uploadTurnWaiters.isEmpty else {
            uploadInProgress = false
            return
        }
        uploadTurnWaiters.removeFirst().resume()
    }
}
