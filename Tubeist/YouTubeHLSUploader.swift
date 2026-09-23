//
//  YouTubeHLSUploader.swift
//  Tubeist
//

import Foundation

struct YouTubeHLSEndpoint: Sendable, Equatable {
    private let value: URL

    init(_ url: URL) throws {
        let host = url.host?.lowercased()
        guard url.scheme?.lowercased() == "https",
              host == "upload.youtube.com" || host?.hasSuffix(".upload.youtube.com") == true,
              url.path == "/http_upload_hls",
              url.absoluteString.hasSuffix("file=") else {
            throw YouTubeHLSUploadError.invalidEndpoint
        }
        self.value = url
    }

#if DEBUG
    init(developmentURL url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              url.path == "/http_upload_hls",
              url.absoluteString.hasSuffix("file=") else {
            throw YouTubeHLSUploadError.invalidEndpoint
        }
        self.value = url
    }
#endif

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
    let maximumRetryDuration: TimeInterval

    init(
        maximumAttempts: Int,
        initialDelay: TimeInterval,
        maximumDelay: TimeInterval,
        jitterFraction: Double,
        maximumRetryDuration: TimeInterval = 120
    ) {
        self.maximumAttempts = maximumAttempts
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.jitterFraction = jitterFraction
        self.maximumRetryDuration = maximumRetryDuration
    }

    static let `default` = YouTubeHLSRetryPolicy(
        // Twenty-three attempts are enough for even minimum-jitter backoff to
        // span the two-minute reconnect budget when failures return instantly.
        maximumAttempts: 23,
        initialDelay: 0.5,
        maximumDelay: 8,
        jitterFraction: 0.2,
        maximumRetryDuration: 120
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
        case .rejected(let statusCode):
            if let meaning = Self.rejectionMeaning(statusCode) {
                "YouTube rejected the stream (HTTP \(statusCode) — \(meaning))"
            } else {
                "YouTube rejected the stream (HTTP \(statusCode))"
            }
        case .retriesExhausted: "The YouTube HLS upload retry limit was reached"
        case .stopped: "The YouTube HLS uploader has stopped"
        }
    }

    var errorDescription: String? { description }

    /// 400, 401 and 405 follow YouTube's HLS ingestion guide; it does not
    /// document 403 or 404, which carry their general HTTP meaning.
    private static func rejectionMeaning(_ statusCode: Int) -> String? {
        switch statusCode {
        case 400: "malformed request or playlist"
        case 401: "stream key invalid or expired"
        case 403: "ingestion not permitted"
        case 404: "ingestion URL not found"
        case 405: "unsupported request method"
        default: nil
        }
    }
}

struct YouTubeHLSUploadReceipt: Sendable, Equatable {
    let sequence: Int
    let segmentFilename: String
    let playlistFilename: String
    var elapsedSeconds: Double = 0
}

struct YouTubeHLSUploaderDiagnostics: Sendable, Equatable {
    let retryCount: Int
    let lastHTTPStatus: Int?
    var isReconnecting: Bool = false
}

/// Frozen at Start so an experiment cannot change shutdown halfway through a stream.
enum HLSStreamEndingPolicy: String, Sendable {
    case automatic
    case manualDiagnostic

    var automaticallyEndsBroadcast: Bool { self == .automatic }
}

actor YouTubeHLSUploader {
    typealias Sleeper = @Sendable (Duration) async throws -> Void
    static let finalSegmentGracePeriod: Duration = .seconds(10)

    private let endpoint: YouTubeHLSEndpoint
    private let userAgent: String
    private let transport: any YouTubeHLSHTTPTransport
    private let retryPolicy: YouTubeHLSRetryPolicy
    private let sleeper: Sleeper
    private let now: @Sendable () -> ContinuousClock.Instant
    private let keepRetrying: Bool
    let endingPolicy: HLSStreamEndingPolicy
    private var playlist: HLSMediaPlaylist
    private var stopped = false
    private var uploadInProgress = false
    private var uploadTurnWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastMegabitsPerSecond = 0
    private var lastUtilization = 0
    private var lastRetryCount = 0
    private var lastHTTPStatus: Int?
    private var isReconnecting = false
    private var lastMediaAcknowledgedAt: ContinuousClock.Instant?
    private var finalPlaylistDelay: Task<Void, Error>?

    init(
        endpoint: YouTubeHLSEndpoint,
        sessionIdentifier: String,
        userAgent: String,
        transport: any YouTubeHLSHTTPTransport = URLSessionYouTubeHLSHTTPTransport(),
        retryPolicy: YouTubeHLSRetryPolicy = .default,
        keepRetrying: Bool = false,
        endingPolicy: HLSStreamEndingPolicy = .automatic,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) throws {
        guard retryPolicy.maximumAttempts > 0,
              retryPolicy.initialDelay >= 0,
              retryPolicy.maximumDelay >= retryPolicy.initialDelay,
              (0...1).contains(retryPolicy.jitterFraction),
              retryPolicy.maximumRetryDuration > 0 else {
            throw YouTubeHLSUploadError.invalidResponse
        }
        self.endpoint = endpoint
        self.userAgent = userAgent
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.sleeper = sleeper
        self.now = now
        self.keepRetrying = keepRetrying
        self.endingPolicy = endingPolicy
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
            lastHTTPStatus: lastHTTPStatus,
            isReconnecting: isReconnecting
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
            let clock = ContinuousClock()
            let uploadStart = clock.now
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
            lastMediaAcknowledgedAt = now()
            lastRetryCount = playlistRetries + segmentRetries
            try playlist.acknowledge(sequence: entry.sequence)
            isReconnecting = false
            let durationComponents = uploadStart.duration(to: clock.now).components
            let measuredElapsed = Double(durationComponents.seconds)
                + Double(durationComponents.attoseconds) / 1_000_000_000_000_000_000
            let elapsed = max(measuredElapsed, 0.001)
            lastMegabitsPerSecond = Int((Double(segment.count) * 8 / 1_000_000) / elapsed)
            lastUtilization = Int((elapsed / duration) * 100)
            return YouTubeHLSUploadReceipt(
                sequence: entry.sequence,
                segmentFilename: entry.filename,
                playlistFilename: playlist.playlistFilename,
                elapsedSeconds: elapsed
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
        finalPlaylistDelay?.cancel()
        await transport.invalidate()
    }

    /// Publishes ENDLIST ten seconds after the final media acknowledgement,
    /// then closes the persistent ingestion connection.
    /// Retains the current playlist window and marks that no more segments follow.
    /// Returns true only when a nonempty final playlist was acknowledged.
    @discardableResult
    func finish(deadline: ContinuousClock.Instant? = nil) async throws -> Bool {
        // Stop also interrupts URLSession, rather than only timing the sleeps
        // between requests. Never outlive the caller's shutdown budget.
        let timeout = deadline.map { deadline in
            Task {
                do { try await Task.sleep(until: deadline, clock: .continuous) }
                catch { return }
                await self.stop()
            }
        }
        defer { timeout?.cancel() }
        await acquireUploadTurn()
        defer { releaseUploadTurn() }
        do {
            guard !stopped, !Task.isCancelled else {
                throw YouTubeHLSUploadError.stopped
            }
            guard playlist.outstandingCount == 0 else {
                throw YouTubeHLSUploadError.invalidResponse
            }
            if !endingPolicy.automaticallyEndsBroadcast {
                // All media has drained. Keep the last rolling playlist open;
                // false also prevents Streamer from requesting API completion.
                stopped = true
                await transport.invalidate()
                return false
            }
            if playlist.nextSequence > 0 {
                guard let lastMediaAcknowledgedAt else {
                    throw YouTubeHLSUploadError.invalidResponse
                }
                let remaining = now().duration(to: lastMediaAcknowledgedAt.advanced(
                    by: Self.finalSegmentGracePeriod
                ))
                if remaining > .zero {
                    let delay = Task { [sleeper] in try await sleeper(remaining) }
                    finalPlaylistDelay = delay
                    defer { finalPlaylistDelay = nil }
                    try await withTaskCancellationHandler {
                        try await delay.value
                    } onCancel: {
                        delay.cancel()
                    }
                }
                _ = try await send(
                    filename: playlist.playlistFilename,
                    contentType: "application/vnd.apple.mpegurl",
                    body: Data(playlist.render(endList: true).utf8),
                    priorRetryCount: 0
                )
            }
            stopped = true
            await transport.invalidate()
            return playlist.nextSequence > 0
        } catch {
            stopped = true
            await transport.invalidate()
            if error is CancellationError {
                throw YouTubeHLSUploadError.stopped
            }
            throw error
        }
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
        let clock = ContinuousClock()
        var retryDeadline = clock.now.advanced(
            by: .seconds(retryPolicy.maximumRetryDuration)
        )
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
                if (400...499).contains(response.statusCode),
                   response.statusCode != 408, response.statusCode != 429 {
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
            isReconnecting = true
            if attempt >= retryPolicy.maximumAttempts || clock.now >= retryDeadline {
                guard keepRetrying else { throw YouTubeHLSUploadError.retriesExhausted }
                // Keep the frozen playlist, media bytes and filename until ACK.
                // A lost response must never allocate another media sequence.
                // Stay at maximum backoff during a prolonged outage.
                retryDeadline = clock.now.advanced(by: .seconds(retryPolicy.maximumRetryDuration))
            }
            let exponent = pow(2, Double(min(attempt - 1, 30)))
            let baseDelay = min(retryPolicy.maximumDelay, retryPolicy.initialDelay * exponent)
            let jitter = retryPolicy.jitterFraction == 0
                ? 1
                : Double.random(in: (1 - retryPolicy.jitterFraction)...(1 + retryPolicy.jitterFraction))
            let remaining = max(.zero, clock.now.duration(to: retryDeadline))
            try await sleeper(min(.seconds(baseDelay * jitter), remaining))
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
