//
//  YouTubeHLSUploaderTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct YouTubeHLSUploaderTests {
    @Test func defaultRetryBudgetOutlivesAOneMinuteConnectivityGap() {
        let policy = YouTubeHLSRetryPolicy.default

        #expect(policy.maximumRetryDuration == 120)
        #expect(policy.maximumAttempts == 23)
    }

    @Test func uploadsPlaylistThenSegmentWithExactRawFileSuffix() async throws {
        let transport = MockYouTubeHLSTransport(statuses: [200, 202, 202, 200])
        let endpoint = try YouTubeHLSEndpoint(URL(
            string: "https://upload.youtube.com/http_upload_hls?cid=secret&copy=0&file="
        )!)
        let uploader = try YouTubeHLSUploader(
            endpoint: endpoint,
            sessionIdentifier: "session_abc",
            userAgent: "Apple/iPhone Tubeist/1.0",
            transport: transport,
            retryPolicy: testRetryPolicy,
            sleeper: { _ in }
        )

        let first = try await uploader.upload(segment: Data([1, 2, 3]), duration: 2)
        let second = try await uploader.upload(segment: Data([4, 5]), duration: 2.1)
        let records = await transport.recordedRequests()

        #expect(first.sequence == 0)
        #expect(second.sequence == 1)
        #expect(records.count == 4)
        #expect(records.map(\.method) == ["POST", "POST", "POST", "POST"])
        #expect(records[0].url.hasSuffix("file=tubeist_session_abc.m3u8"))
        #expect(records[1].url.hasSuffix("file=tubeist_session_abc_0.ts"))
        #expect(records[2].url.hasSuffix("file=tubeist_session_abc.m3u8"))
        #expect(records[3].url.hasSuffix("file=tubeist_session_abc_1.ts"))
        #expect(!records.map(\.url).contains { $0.contains("%2E") || $0.contains("%5F") })
        #expect(records[0].contentType == "application/vnd.apple.mpegurl")
        #expect(records[1].contentType == "video/mp2t")
        #expect(records.allSatisfy { $0.userAgent == "Apple/iPhone Tubeist/1.0" })
        #expect(records[1].body == Data([1, 2, 3]))
        #expect(records[3].body == Data([4, 5]))

        let firstPlaylist = try #require(String(data: records[0].body, encoding: .utf8))
        let secondPlaylist = try #require(String(data: records[2].body, encoding: .utf8))
        #expect(firstPlaylist.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        #expect(firstPlaylist.contains("tubeist_session_abc_0.ts"))
        #expect(!firstPlaylist.contains("tubeist_session_abc_1.ts"))
        #expect(secondPlaylist.contains("tubeist_session_abc_0.ts"))
        #expect(secondPlaylist.contains("tubeist_session_abc_1.ts"))
        #expect(await uploader.outstandingCount == 0)
    }

    @Test func retriesServerAndNetworkFailuresWithoutRenaming() async throws {
        let transport = MockYouTubeHLSTransport(outcomes: [
            .status(500),
            .networkFailure,
            .status(202),
            .status(200),
        ])
        let endpoint = try YouTubeHLSEndpoint(URL(
            string: "https://upload.youtube.com/http_upload_hls?cid=redacted&file="
        )!)
        let uploader = try YouTubeHLSUploader(
            endpoint: endpoint,
            sessionIdentifier: "retry_session",
            userAgent: "Tubeist/Test",
            transport: transport,
            retryPolicy: testRetryPolicy,
            sleeper: { _ in }
        )

        _ = try await uploader.upload(segment: Data([0x47]), duration: 1)
        let records = await transport.recordedRequests()
        #expect(records.count == 4)
        #expect(Set(records.prefix(3).map(\.url)).count == 1)
        #expect(records[3].url.hasSuffix("tubeist_retry_session_0.ts"))
        let diagnostics = await uploader.diagnostics
        #expect(diagnostics.retryCount == 2)
        #expect(diagnostics.lastHTTPStatus == 200)
    }

    @Test func rejectsLateSuccessAfterStopOrTaskCancellation() async throws {
        let endpoint = try YouTubeHLSEndpoint(URL(
            string: "https://upload.youtube.com/http_upload_hls?cid=redacted&file="
        )!)

        let stoppedTransport = MockYouTubeHLSTransport(outcomes: [.delayedStatus(200)])
        let stoppedUploader = try YouTubeHLSUploader(
            endpoint: endpoint,
            sessionIdentifier: "stop_session",
            userAgent: "Tubeist/Test",
            transport: stoppedTransport,
            retryPolicy: testRetryPolicy,
            sleeper: { _ in }
        )
        let stoppedUpload = Task {
            try await stoppedUploader.upload(segment: Data([0x47]), duration: 1)
        }
        await waitForRequest(on: stoppedTransport)
        await stoppedUploader.stop()
        do {
            _ = try await stoppedUpload.value
            Issue.record("Expected an in-flight upload to stop")
        } catch let error as YouTubeHLSUploadError {
            #expect(error == .stopped)
        }

        let cancelledTransport = MockYouTubeHLSTransport(outcomes: [.delayedStatus(200)])
        let cancelledUploader = try YouTubeHLSUploader(
            endpoint: endpoint,
            sessionIdentifier: "cancel_session",
            userAgent: "Tubeist/Test",
            transport: cancelledTransport,
            retryPolicy: testRetryPolicy,
            sleeper: { _ in }
        )
        let cancelledUpload = Task {
            try await cancelledUploader.upload(segment: Data([0x47]), duration: 1)
        }
        await waitForRequest(on: cancelledTransport)
        cancelledUpload.cancel()
        do {
            _ = try await cancelledUpload.value
            Issue.record("Expected a cancelled upload to stop")
        } catch let error as YouTubeHLSUploadError {
            #expect(error == .stopped)
        }
    }

    @Test(arguments: [400, 401, 405])
    func treatsProtocolAndAuthenticationFailuresAsFatal(statusCode: Int) async throws {
        let transport = MockYouTubeHLSTransport(statuses: [statusCode])
        let endpoint = try YouTubeHLSEndpoint(URL(
            string: "https://upload.youtube.com/http_upload_hls?cid=redacted&file="
        )!)
        let uploader = try YouTubeHLSUploader(
            endpoint: endpoint,
            sessionIdentifier: "fatal_session",
            userAgent: "Tubeist/Test",
            transport: transport,
            retryPolicy: testRetryPolicy,
            sleeper: { _ in }
        )
        do {
            _ = try await uploader.upload(segment: Data([0x47]), duration: 1)
            Issue.record("Expected fatal HTTP rejection")
        } catch let error as YouTubeHLSUploadError {
            #expect(error == .rejected(statusCode: statusCode))
        }
        #expect(await transport.recordedRequests().count == 1)
    }

    @Test func serializesConcurrentCallersAndExhaustsRetriesDeterministically() async throws {
        let serialTransport = MockYouTubeHLSTransport(outcomes: [
            .delayedStatus(200), .status(200), .status(200), .status(200),
        ])
        let endpoint = try YouTubeHLSEndpoint(URL(
            string: "https://upload.youtube.com/http_upload_hls?cid=redacted&file="
        )!)
        let uploader = try YouTubeHLSUploader(
            endpoint: endpoint,
            sessionIdentifier: "serial_session",
            userAgent: "Tubeist/Test",
            transport: serialTransport,
            retryPolicy: testRetryPolicy,
            sleeper: { _ in }
        )
        async let first = uploader.upload(segment: Data([1]), duration: 1)
        await Task.yield()
        async let second = uploader.upload(segment: Data([2]), duration: 1)
        _ = try await (first, second)
        let serialRecords = await serialTransport.recordedRequests()
        #expect(serialRecords.count == 4)
        #expect(serialRecords[0].url.hasSuffix(".m3u8"))
        #expect(serialRecords[1].url.hasSuffix("_0.ts"))
        #expect(serialRecords[2].url.hasSuffix(".m3u8"))
        #expect(serialRecords[3].url.hasSuffix("_1.ts"))

        let failingTransport = MockYouTubeHLSTransport(statuses: [500, 500, 500, 500])
        let failingUploader = try YouTubeHLSUploader(
            endpoint: endpoint,
            sessionIdentifier: "exhausted_session",
            userAgent: "Tubeist/Test",
            transport: failingTransport,
            retryPolicy: testRetryPolicy,
            sleeper: { _ in }
        )
        do {
            _ = try await failingUploader.upload(segment: Data([3]), duration: 1)
            Issue.record("Expected retries to be exhausted")
        } catch let error as YouTubeHLSUploadError {
            #expect(error == .retriesExhausted)
        }
        let retryRecords = await failingTransport.recordedRequests()
        #expect(retryRecords.count == testRetryPolicy.maximumAttempts)
        #expect(Set(retryRecords.map(\.url)).count == 1)
        #expect(await failingUploader.outstandingCount == 1)

        await failingUploader.stop()
        do {
            _ = try await failingUploader.upload(segment: Data([4]), duration: 1)
            Issue.record("Expected stopped uploader to reject new work")
        } catch let error as YouTubeHLSUploadError {
            #expect(error == .stopped)
        }
    }

    @Test func permanentFailureAndCancelledWaiterCannotStartMoreRequests() async throws {
        let endpoint = try YouTubeHLSEndpoint(URL(
            string: "https://upload.youtube.com/http_upload_hls?cid=redacted&file="
        )!)
        let rejectedTransport = MockYouTubeHLSTransport(outcomes: [
            .delayedStatus(400), .status(200), .status(200),
        ])
        let rejectedUploader = try YouTubeHLSUploader(
            endpoint: endpoint,
            sessionIdentifier: "rejected_queue",
            userAgent: "Tubeist/Test",
            transport: rejectedTransport,
            retryPolicy: testRetryPolicy,
            sleeper: { _ in }
        )
        let rejectedFirst = Task {
            try await rejectedUploader.upload(segment: Data([1]), duration: 1)
        }
        await waitForRequest(on: rejectedTransport)
        let rejectedSecond = Task {
            try await rejectedUploader.upload(segment: Data([2]), duration: 1)
        }
        do {
            _ = try await rejectedFirst.value
            Issue.record("Expected the first queued upload to be rejected")
        } catch let error as YouTubeHLSUploadError {
            #expect(error == .rejected(statusCode: 400))
        }
        do {
            _ = try await rejectedSecond.value
            Issue.record("Expected the second queued upload to stop")
        } catch let error as YouTubeHLSUploadError {
            #expect(error == .stopped)
        }
        #expect(await rejectedTransport.recordedRequests().count == 1)

        let cancelledTransport = MockYouTubeHLSTransport(outcomes: [
            .delayedStatus(200), .status(200), .status(200),
        ])
        let cancelledUploader = try YouTubeHLSUploader(
            endpoint: endpoint,
            sessionIdentifier: "cancelled_queue",
            userAgent: "Tubeist/Test",
            transport: cancelledTransport,
            retryPolicy: testRetryPolicy,
            sleeper: { _ in }
        )
        let activeUpload = Task {
            try await cancelledUploader.upload(segment: Data([1]), duration: 1)
        }
        await waitForRequest(on: cancelledTransport)
        let cancelledWaiter = Task {
            try await cancelledUploader.upload(segment: Data([2]), duration: 1)
        }
        cancelledWaiter.cancel()
        _ = try await activeUpload.value
        do {
            _ = try await cancelledWaiter.value
            Issue.record("Expected the cancelled waiter to stop")
        } catch let error as YouTubeHLSUploadError {
            #expect(error == .stopped)
        }
        #expect(await cancelledTransport.recordedRequests().count == 2)
    }

    @Test func buildsOfficialManualEndpointWithoutEncodingFilename() throws {
        let endpoint = try YouTubeHLSEndpoint.manualPrimary(streamKey: "abcd-efgh-1234")
        let url = try endpoint.requestURL(filename: "session_0.ts")
        #expect(url.absoluteString == "https://a.upload.youtube.com/http_upload_hls?cid=abcd-efgh-1234&copy=0&file=session_0.ts")
        #expect(throws: YouTubeHLSUploadError.self) {
            _ = try YouTubeHLSEndpoint.manualPrimary(streamKey: "not/a/key")
        }
    }

    @Test(arguments: [
        "http://a.upload.youtube.com/http_upload_hls?cid=key&file=",
        "https://example.invalid/http_upload_hls?cid=key&file=",
        "https://a.upload.youtube.com/other?cid=key&file=",
        "https://a.upload.youtube.com/http_upload_hls?cid=key",
    ])
    func rejectsNonYouTubeOrMalformedIngestionEndpoints(_ value: String) throws {
        let url = try #require(URL(string: value))
        #expect(throws: YouTubeHLSUploadError.self) {
            _ = try YouTubeHLSEndpoint(url)
        }
    }

    @Test func publicErrorsDoNotExposeTheEndpointOrStreamKey() async throws {
        let secret = "secret-key-never-log"
        let endpoint = try YouTubeHLSEndpoint(URL(
            string: "https://upload.youtube.com/http_upload_hls?cid=\(secret)&file="
        )!)
        let transport = MockYouTubeHLSTransport(statuses: [401])
        let uploader = try YouTubeHLSUploader(
            endpoint: endpoint,
            sessionIdentifier: "redaction_session",
            userAgent: "Tubeist/Test",
            transport: transport,
            retryPolicy: testRetryPolicy,
            sleeper: { _ in }
        )
        do {
            _ = try await uploader.upload(segment: Data([0x47]), duration: 1)
            Issue.record("Expected the upload to be rejected")
        } catch {
            let description = String(describing: error)
            #expect(!description.contains(secret))
            #expect(!description.contains("http_upload_hls"))
            #expect(!description.contains("upload.youtube.com"))
        }
    }

    @Test func keepsALongSequentialStreamWindowBounded() async throws {
        let transport = MockYouTubeHLSTransport(statuses: [])
        let endpoint = try YouTubeHLSEndpoint(URL(
            string: "https://upload.youtube.com/http_upload_hls?cid=redacted&file="
        )!)
        let uploader = try YouTubeHLSUploader(
            endpoint: endpoint,
            sessionIdentifier: "long_session",
            userAgent: "Tubeist/Test",
            transport: transport,
            retryPolicy: testRetryPolicy,
            sleeper: { _ in }
        )
        for sequence in 0..<50 {
            let receipt = try await uploader.upload(
                segment: Data([UInt8(sequence)]),
                duration: 2
            )
            #expect(receipt.sequence == sequence)
        }

        let requests = await transport.recordedRequests()
        #expect(requests.count == 100)
        let playlists = requests.enumerated().compactMap { index, request in
            index.isMultiple(of: 2) ? String(data: request.body, encoding: .utf8) : nil
        }
        #expect(playlists.count == 50)
        let lastPlaylist = try #require(playlists.last)
        #expect(lastPlaylist.contains("#EXT-X-MEDIA-SEQUENCE:47"))
        #expect(lastPlaylist.contains("tubeist_long_session_47.ts"))
        #expect(lastPlaylist.contains("tubeist_long_session_48.ts"))
        #expect(lastPlaylist.contains("tubeist_long_session_49.ts"))
        #expect(!lastPlaylist.contains("tubeist_long_session_46.ts"))
        #expect(await uploader.outstandingCount == 0)
    }
}

private func waitForRequest(on transport: MockYouTubeHLSTransport) async {
    for _ in 0..<1_000 {
        if await !transport.recordedRequests().isEmpty {
            return
        }
        await Task.yield()
    }
}

private let testRetryPolicy = YouTubeHLSRetryPolicy(
    maximumAttempts: 4,
    initialDelay: 0,
    maximumDelay: 0,
    jitterFraction: 0
)

private struct MockRequestRecord: Sendable {
    let method: String
    let url: String
    let contentType: String?
    let userAgent: String?
    let body: Data
}

private enum MockTransportOutcome: Sendable {
    case status(Int)
    case delayedStatus(Int)
    case networkFailure
}

private enum MockNetworkError: Error {
    case offline
}

private actor MockYouTubeHLSTransport: YouTubeHLSHTTPTransport {
    private var outcomes: [MockTransportOutcome]
    private var records: [MockRequestRecord] = []

    init(statuses: [Int]) {
        self.outcomes = statuses.map(MockTransportOutcome.status)
    }

    init(outcomes: [MockTransportOutcome]) {
        self.outcomes = outcomes
    }

    func send(_ request: URLRequest, body: Data) async throws -> YouTubeHLSHTTPResponse {
        records.append(MockRequestRecord(
            method: request.httpMethod ?? "",
            url: request.url?.absoluteString ?? "",
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            userAgent: request.value(forHTTPHeaderField: "User-Agent"),
            body: body
        ))
        let outcome = outcomes.isEmpty ? .status(200) : outcomes.removeFirst()
        switch outcome {
        case .status(let status): return YouTubeHLSHTTPResponse(statusCode: status)
        case .delayedStatus(let status):
            try await Task.sleep(for: .milliseconds(20))
            return YouTubeHLSHTTPResponse(statusCode: status)
        case .networkFailure: throw MockNetworkError.offline
        }
    }

    func invalidate() {}

    func recordedRequests() -> [MockRequestRecord] {
        records
    }
}
