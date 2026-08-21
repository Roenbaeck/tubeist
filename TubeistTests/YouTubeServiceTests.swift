//
//  YouTubeServiceTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct YouTubeServiceTests {
    @Test func formEncodingEscapesReservedAndUnicodeBytes() {
        let encoded = FormURLEncoder.encode([
            "space key": "a+b&c=d/? é",
            "plain": "-._~AZaz09",
        ])

        #expect(String(decoding: encoded, as: UTF8.self) ==
            "plain=-._~AZaz09&space%20key=a%2Bb%26c%3Dd%2F%3F%20%C3%A9")
    }

    @Test func requestExecutorRejectsNonHTTPSBeforeTransport() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(data: Data(), statusCode: 200),
        ])
        let executor = YouTubeAPIRequestExecutor(transport: transport)

        do {
            _ = try await executor.data(for: URLRequest(url: URL(string: "http://example.invalid")!))
            Issue.record("Expected HTTP to be rejected")
        } catch let error as YouTubeError {
            #expect(error == .invalidResponse)
        }
        #expect(await transport.requestCount == 0)
    }

    @Test func requestExecutorReturnsSuccessfulBodyAndRejectsHTTPFailure() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(data: Data("ok".utf8), statusCode: 204),
            YouTubeAPIResponse(
                data: Data(#"{"error":{"message":"quota exceeded"}}"#.utf8),
                statusCode: 403
            ),
        ])
        let executor = YouTubeAPIRequestExecutor(transport: transport)
        let request = URLRequest(url: URL(string: "https://example.invalid/api")!)

        let data = try await executor.data(for: request)
        #expect(String(decoding: data, as: UTF8.self) == "ok")

        do {
            _ = try await executor.data(for: request)
            Issue.record("Expected a non-2xx response to fail")
        } catch let error as YouTubeError {
            #expect(error == .apiError(403, "quota exceeded"))
        }
        #expect(await transport.requestCount == 2)
    }

    @Test func requestExecutorDecodesTypedResponsesAndRejectsSchemaDrift() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"playlist-1","snippet":{"title":"Live archives"}}]}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"items":"not-an-array"}"#.utf8),
                statusCode: 200
            ),
        ])
        let executor = YouTubeAPIRequestExecutor(transport: transport)
        let request = URLRequest(url: URL(string: "https://example.invalid/playlists")!)

        let response = try await executor.decode(
            YouTubeListResponse<YouTubePlaylistResource>.self,
            for: request
        )
        #expect(response.items.first?.id == "playlist-1")
        #expect(response.items.first?.snippet?.title == "Live archives")

        await #expect(throws: YouTubeError.invalidResponse) {
            _ = try await executor.decode(
                YouTubeListResponse<YouTubePlaylistResource>.self,
                for: request
            )
        }
    }

    @Test func requestExecutorRedactsMalformedAPIErrorBodies() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(data: Data("gateway html containing a secret".utf8), statusCode: 502),
        ])
        let executor = YouTubeAPIRequestExecutor(transport: transport)
        let request = URLRequest(url: URL(string: "https://example.invalid/api")!)

        do {
            _ = try await executor.data(for: request)
            Issue.record("Expected a non-JSON API failure")
        } catch let error as YouTubeError {
            #expect(error == .apiError(502, "The request was rejected"))
            #expect(!error.localizedDescription.contains("secret"))
        }
    }

    @Test func requestExecutorDecodesTypedOAuthErrorsWithoutEchoingTheBody() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(
                data: Data(#"{"error":"invalid_grant","error_description":"Authorization expired"}"#.utf8),
                statusCode: 400
            ),
        ])
        let executor = YouTubeAPIRequestExecutor(transport: transport)

        do {
            _ = try await executor.data(
                for: URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
            )
            Issue.record("Expected the OAuth error response to fail")
        } catch let error as YouTubeError {
            #expect(error == .apiError(400, "Authorization expired"))
            #expect(!error.localizedDescription.contains("invalid_grant"))
        }
    }

    @Test func discoversTheMatchingHLSStreamAndRetainsBothAddresses() throws {
        let data = try streamsResponse([
            streamItem(
                id: "other",
                key: "other-key",
                type: "rtmp",
                address: "rtmp://example.invalid/live"
            ),
            streamItem(
                id: "wanted",
                key: "test-key",
                type: "HLS",
                address: "https://a.upload.youtube.com/http_upload_hls?cid=test-key&copy=0&file=",
                backupAddress: "https://b.upload.youtube.com/http_upload_hls?cid=test-key&copy=1&file="
            ),
        ])

        let stream = try YouTubeStreamDiscovery.findStream(
            in: data,
            matchingStreamKey: "test-key"
        )
        #expect(stream.id == "wanted")
        #expect(stream.ingestionType == "HLS")
        #expect(stream.backupIngestionAddress?.contains("copy=1") == true)

        let endpoint = try YouTubeStreamDiscovery.hlsEndpoint(for: stream)
        let requestURL = try endpoint.requestURL(filename: "tubeist_fixture_0.ts")
        #expect(requestURL.absoluteString.hasSuffix("file=tubeist_fixture_0.ts"))
    }

    @Test func rejectsAMatchingRTMPStreamForDirectHLS() throws {
        let stream = YouTubeStream(
            id: "rtmp-stream",
            streamName: "test-key",
            publishedAt: nil,
            ingestionType: "rtmp",
            ingestionAddress: "rtmp://example.invalid/live",
            backupIngestionAddress: nil
        )

        do {
            _ = try YouTubeStreamDiscovery.hlsEndpoint(for: stream)
            Issue.record("Expected RTMP ingestion to be rejected")
        } catch let error as YouTubeError {
            #expect(error == .incompatibleIngestionType("rtmp"))
        }
    }

    @Test(arguments: [
        "http://a.upload.youtube.com/http_upload_hls?cid=test-key&file=",
        "https://a.upload.youtube.com/http_upload_hls?cid=test-key",
    ])
    func rejectsUnsafeOrIncompleteHLSIngestionAddresses(_ address: String) {
        let stream = YouTubeStream(
            id: "invalid-address",
            streamName: "test-key",
            publishedAt: nil,
            ingestionType: "hls",
            ingestionAddress: address,
            backupIngestionAddress: nil
        )

        do {
            _ = try YouTubeStreamDiscovery.hlsEndpoint(for: stream)
            Issue.record("Expected invalid HLS ingestion address to be rejected")
        } catch let error as YouTubeError {
            #expect(error == .invalidIngestionAddress)
        } catch {
            Issue.record("Unexpected endpoint-discovery error: \(error)")
        }
    }

    @Test func distinguishesNoMatchFromMalformedMatchingMetadata() throws {
        do {
            _ = try YouTubeStreamDiscovery.findStream(
                in: Data("not-json".utf8),
                matchingStreamKey: "test-key"
            )
            Issue.record("Expected invalid JSON to fail")
        } catch let error as YouTubeError {
            #expect(error == .invalidResponse)
        }

        let noMatch = try streamsResponse([
            streamItem(
                id: "other",
                key: "other-key",
                type: "hls",
                address: "https://example.invalid/upload?file="
            ),
        ])
        do {
            _ = try YouTubeStreamDiscovery.findStream(in: noMatch, matchingStreamKey: "test-key")
            Issue.record("Expected an unmatched key to fail")
        } catch let error as YouTubeError {
            #expect(error == .noStreamFound)
        }

        let malformedMatch = try streamsResponse([
            [
                "id": "broken",
                "cdn": [
                    "ingestionType": "hls",
                    "ingestionInfo": ["streamName": "test-key"],
                ],
            ],
        ])
        do {
            _ = try YouTubeStreamDiscovery.findStream(
                in: malformedMatch,
                matchingStreamKey: "test-key"
            )
            Issue.record("Expected incomplete matching metadata to fail")
        } catch let error as YouTubeError {
            #expect(error == .invalidResponse)
        }
    }

    @Test func selectsTheNewestStreamResourceWhenAReusableKeyAppearsMoreThanOnce() throws {
        let data = try streamsResponse([
            streamItem(
                id: "old-stream-resource",
                key: "reused-key",
                type: "hls",
                address: "https://old.upload.youtube.com/http_upload_hls?cid=reused-key&file=",
                publishedAt: "2024-01-01T00:00:00Z"
            ),
            streamItem(
                id: "new-stream-resource",
                key: "reused-key",
                type: "hls",
                address: "https://new.upload.youtube.com/http_upload_hls?cid=reused-key&file=",
                publishedAt: "2026-08-19T06:00:00.123Z"
            ),
        ])

        let selected = try YouTubeStreamDiscovery.findStream(
            in: data,
            matchingStreamKey: "reused-key"
        )

        #expect(selected.id == "new-stream-resource")
        #expect(selected.ingestionAddress.contains("new.upload.youtube.com"))
    }

    @Test func selectsARecentCompletedBroadcastOverAnOldReadyBroadcast() {
        let oldReady = broadcast(
            id: "old-ready",
            title: "Old stream",
            status: "ready",
            scheduledStartTime: "2024-01-01T12:00:00Z"
        )
        let recentComplete = broadcast(
            id: "recent-complete",
            title: "Most recent stream",
            status: "complete",
            scheduledStartTime: "2026-08-19T06:00:00Z",
            actualStartTime: "2026-08-19T06:01:00.123Z"
        )
        let revoked = broadcast(
            id: "revoked",
            title: "Revoked stream",
            status: "revoked",
            scheduledStartTime: "2027-01-01T00:00:00Z"
        )

        let selected = YouTubeBroadcastDiscovery.selectCurrentOrMostRecent(
            from: [oldReady, recentComplete, revoked]
        )

        #expect(selected?.id == "recent-complete")
    }

    @Test func selectsTheCurrentActiveBroadcastBeforeAFutureBroadcast() {
        let active = broadcast(
            id: "active",
            title: "Live now",
            status: "live",
            scheduledStartTime: "2026-08-19T06:00:00Z",
            actualStartTime: "2026-08-19T06:01:00Z"
        )
        let future = broadcast(
            id: "future",
            title: "Tomorrow",
            status: "ready",
            scheduledStartTime: "2026-08-20T06:00:00Z"
        )

        let selected = YouTubeBroadcastDiscovery.selectCurrentOrMostRecent(
            from: [future, active]
        )

        #expect(selected?.id == "active")
    }

    @Test func treatsAStartingBroadcastAsActive() {
        let starting = broadcast(
            id: "starting",
            title: "Starting now",
            status: "liveStarting",
            scheduledStartTime: "2026-08-19T06:00:00Z"
        )
        let future = broadcast(
            id: "future",
            title: "Tomorrow",
            status: "ready",
            scheduledStartTime: "2026-08-20T06:00:00Z"
        )

        let selected = YouTubeBroadcastDiscovery.selectCurrentOrMostRecent(
            from: [future, starting]
        )

        #expect(selected?.id == "starting")
        #expect(selected?.isActive == true)
    }

    @Test @MainActor
    func authenticatedRequestRefreshesExactlyOnceAfterA401() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let store = MemoryYouTubeTokenStore(
            accessToken: "expired-access",
            refreshToken: "refresh-token",
            expiry: fixedNow.addingTimeInterval(600)
        )
        let transport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(
                data: Data(#"{"error":{"message":"expired"}}"#.utf8),
                statusCode: 401
            ),
            YouTubeAPIResponse(
                data: Data(#"{"access_token":"fresh-access","expires_in":3600}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"broadcast-1","status":{"lifeCycleStatus":"live"}}]}"#.utf8),
                statusCode: 200
            ),
        ])
        let service = YouTubeService(
            transport: transport,
            tokenStore: store,
            now: { fixedNow }
        )

        #expect(try await service.fetchBroadcastStatus(broadcastId: "broadcast-1") == "live")
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer expired-access")
        #expect(requests[1].url?.absoluteString == YOUTUBE_TOKEN_URL)
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer fresh-access")
        #expect(store.accessToken == "fresh-access")
    }

    @Test @MainActor
    func concurrentRequestsShareOneTokenRefresh() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let store = MemoryYouTubeTokenStore(
            accessToken: nil,
            refreshToken: "refresh-token",
            expiry: nil
        )
        let transport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(
                data: Data(#"{"access_token":"shared-access","expires_in":3600}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"status":{"lifeCycleStatus":"ready"}}]}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"status":{"lifeCycleStatus":"testing"}}]}"#.utf8),
                statusCode: 200
            ),
        ])
        let service = YouTubeService(
            transport: transport,
            tokenStore: store,
            now: { fixedNow }
        )

        async let first = service.fetchBroadcastStatus(broadcastId: "one")
        async let second = service.fetchBroadcastStatus(broadcastId: "two")
        let statuses = try await (first, second)

        #expect(Set([statuses.0, statuses.1].compactMap { $0 }) == Set(["ready", "testing"]))
        let requests = await transport.requests
        #expect(requests.filter { $0.url?.absoluteString == YOUTUBE_TOKEN_URL }.count == 1)
        #expect(requests.filter { $0.value(forHTTPHeaderField: "Authorization") == "Bearer shared-access" }.count == 2)
    }

    @Test @MainActor
    func playlistLookupPaginatesAndPreservesServerOrder() async throws {
        let store = validMemoryTokenStore()
        let transport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"p1","snippet":{"title":"First"}}],"nextPageToken":"page-2"}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"p2","snippet":{"title":"Second"}}]}"#.utf8),
                statusCode: 200
            ),
        ])
        let service = YouTubeService(transport: transport, tokenStore: store)

        let playlists = try await service.listPlaylists()

        #expect(playlists.map(\.id) == ["p1", "p2"])
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(URLComponents(url: try #require(requests[1].url), resolvingAgainstBaseURL: false)?
            .queryItems?.contains(URLQueryItem(name: "pageToken", value: "page-2")) == true)
    }

    @Test @MainActor
    func broadcastMutationsUseExpectedMethodsAndTypedResponses() async throws {
        let store = validMemoryTokenStore()
        let transport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(data: Data(#"{"id":"broadcast-1"}"#.utf8), statusCode: 200),
            YouTubeAPIResponse(data: Data(#"{"id":"broadcast-1"}"#.utf8), statusCode: 200),
        ])
        let service = YouTubeService(transport: transport, tokenStore: store)

        try await service.updateBroadcast(
            id: "broadcast-1",
            title: "Updated",
            privacyStatus: "unlisted",
            scheduledStartTime: nil,
            enableDvr: true,
            latencyPreference: "low",
            enableMonitorStream: false,
            broadcastStreamDelayMs: 0,
            enableEmbed: true,
            recordFromStart: true,
            enableAutoStart: true,
            enableAutoStop: true
        )
        try await service.stopBroadcast(id: "broadcast-1")

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["PUT", "POST"])
        #expect(requests[0].httpBody?.range(of: Data("Updated".utf8)) != nil)
        #expect(requests[1].url?.path.hasSuffix("/liveBroadcasts/transition") == true)
    }

    @Test @MainActor
    func playlistMutationIsIdempotentAndValidatesInsertionResponse() async throws {
        let existingTransport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(data: Data(#"{"items":[{"id":"already-there"}]}"#.utf8), statusCode: 200),
        ])
        let existingService = YouTubeService(
            transport: existingTransport,
            tokenStore: validMemoryTokenStore()
        )
        try await existingService.addToPlaylist(playlistId: "playlist", videoId: "video")
        #expect(await existingTransport.requestCount == 1)

        let insertionTransport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(data: Data(#"{"items":[]}"#.utf8), statusCode: 200),
            YouTubeAPIResponse(data: Data(#"{"id":"playlist-item"}"#.utf8), statusCode: 200),
        ])
        let insertionService = YouTubeService(
            transport: insertionTransport,
            tokenStore: validMemoryTokenStore()
        )
        try await insertionService.addToPlaylist(playlistId: "playlist", videoId: "video")
        let insertionRequests = await insertionTransport.requests
        #expect(insertionRequests[0].httpMethod == "GET")
        #expect(insertionRequests[1].httpMethod == "POST")
    }

    @Test @MainActor
    func completedBroadcastCreatesAndBindsOneTypedSuccessor() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"stream-1","cdn":{"ingestionType":"hls","ingestionInfo":{"streamName":"test-key","ingestionAddress":"https://a.upload.youtube.com/http_upload_hls?cid=test-key&file="}}}]}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"completed","snippet":{"title":"Previous","scheduledStartTime":"2024-01-01T00:00:00Z"},"status":{"privacyStatus":"unlisted","lifeCycleStatus":"complete"},"contentDetails":{"boundStreamId":"stream-1"}}]}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"id":"inserted","snippet":{"title":"Previous"},"status":{"privacyStatus":"unlisted","lifeCycleStatus":"ready"},"contentDetails":{}}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"id":"bound","snippet":{"title":"Previous"},"status":{"privacyStatus":"unlisted","lifeCycleStatus":"ready"},"contentDetails":{"boundStreamId":"stream-1"}}"#.utf8),
                statusCode: 200
            ),
        ])
        let service = YouTubeService(
            transport: transport,
            tokenStore: validMemoryTokenStore()
        )

        let successor = try await service.ensureCurrentBroadcastForStreamKey("test-key")

        #expect(successor.id == "bound")
        #expect(successor.boundStreamId == "stream-1")
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "POST", "POST"])
        #expect(requests[2].url?.path.hasSuffix("/liveBroadcasts") == true)
        #expect(requests[3].url?.path.hasSuffix("/liveBroadcasts/bind") == true)
    }

    @Test @MainActor
    func streamingPreflightCreatesAReadySuccessorBeforeReturningTheEndpoint() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"stream-1","cdn":{"ingestionType":"hls","ingestionInfo":{"streamName":"test-key","ingestionAddress":"https://a.upload.youtube.com/http_upload_hls?cid=test-key&file="}}}]}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"completed","snippet":{"title":"Previous","scheduledStartTime":"2024-01-01T00:00:00Z"},"status":{"privacyStatus":"unlisted","lifeCycleStatus":"complete"},"contentDetails":{"boundStreamId":"stream-1"}}]}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"id":"inserted","snippet":{"title":"Previous"},"status":{"privacyStatus":"unlisted","lifeCycleStatus":"ready"},"contentDetails":{}}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"id":"bound","snippet":{"title":"Previous"},"status":{"privacyStatus":"unlisted","lifeCycleStatus":"ready"},"contentDetails":{"boundStreamId":"stream-1"}}"#.utf8),
                statusCode: 200
            ),
        ])
        let service = YouTubeService(
            transport: transport,
            tokenStore: validMemoryTokenStore()
        )

        let preparation = try await service.prepareForStreaming(streamKey: "test-key")

        #expect(preparation.broadcast.id == "bound")
        #expect(preparation.broadcast.lifeCycleStatus == "ready")
        let mediaURL = try preparation.endpoint.requestURL(filename: "media_0.ts")
        #expect(mediaURL.host == "a.upload.youtube.com")
        #expect(mediaURL.lastPathComponent == "http_upload_hls")
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "POST", "POST"])
    }

    @Test @MainActor
    func streamingPreflightReusesReadyAndRejectsStillActiveBroadcasts() async throws {
        let readyTransport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"stream-1","cdn":{"ingestionType":"hls","ingestionInfo":{"streamName":"test-key","ingestionAddress":"https://a.upload.youtube.com/http_upload_hls?cid=test-key&file="}}}]}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"ready","snippet":{"title":"Next"},"status":{"privacyStatus":"unlisted","lifeCycleStatus":"ready"},"contentDetails":{"boundStreamId":"stream-1"}}]}"#.utf8),
                statusCode: 200
            ),
        ])
        let readyService = YouTubeService(
            transport: readyTransport,
            tokenStore: validMemoryTokenStore()
        )

        let preparation = try await readyService.prepareForStreaming(streamKey: "test-key")
        #expect(preparation.broadcast.id == "ready")
        #expect(await readyTransport.requestCount == 2)

        let activeTransport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"stream-1","cdn":{"ingestionType":"hls","ingestionInfo":{"streamName":"test-key","ingestionAddress":"https://a.upload.youtube.com/http_upload_hls?cid=test-key&file="}}}]}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"active","snippet":{"title":"Previous"},"status":{"privacyStatus":"unlisted","lifeCycleStatus":"liveStarting"},"contentDetails":{"boundStreamId":"stream-1"}}]}"#.utf8),
                statusCode: 200
            ),
        ])
        let activeService = YouTubeService(
            transport: activeTransport,
            tokenStore: validMemoryTokenStore()
        )

        await #expect(throws: YouTubeError.broadcastNotReady("starting live stream")) {
            _ = try await activeService.prepareForStreaming(streamKey: "test-key")
        }
        #expect(await activeTransport.requestCount == 2)
    }

    @Test @MainActor
    func thumbnailMutationPreservesBinaryBodyAndMetadata() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(data: Data(), statusCode: 200),
        ])
        let service = YouTubeService(
            transport: transport,
            tokenStore: validMemoryTokenStore()
        )
        let image = Data([0xFF, 0xD8, 0xFF, 0xD9])

        try await service.uploadThumbnail(videoId: "video-1", imageData: image)

        let requests = await transport.requests
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == image)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        #expect(request.value(forHTTPHeaderField: "Content-Length") == "4")
    }

    @Test @MainActor
    func repeatedPaginationTokenIsRejected() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(
                data: Data(#"{"items":[],"nextPageToken":"cycle"}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"items":[],"nextPageToken":"cycle"}"#.utf8),
                statusCode: 200
            ),
        ])
        let service = YouTubeService(
            transport: transport,
            tokenStore: validMemoryTokenStore()
        )

        await #expect(throws: YouTubeError.invalidResponse) {
            _ = try await service.listPlaylists()
        }
        #expect(await transport.requestCount == 2)
    }

    @Test @MainActor
    func cancellationPropagatesAndClearsLoadingState() async throws {
        let transport = SuspendingYouTubeAPITransport()
        let service = YouTubeService(
            transport: transport,
            tokenStore: validMemoryTokenStore()
        )
        let task = Task {
            try await service.listPlaylists()
        }
        await transport.waitUntilStarted()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(!service.isLoading)
        #expect(await transport.observedCancellation)
    }
}

private final class MemoryYouTubeTokenStore: YouTubeTokenStoring {
    var accessToken: String?
    var refreshToken: String?
    var expiry: Date?

    init(accessToken: String?, refreshToken: String?, expiry: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiry = expiry
    }

    func setAccessToken(_ value: String?) throws {
        accessToken = value
    }

    func setRefreshToken(_ value: String?) throws {
        refreshToken = value
    }

    func clearAuthorization() throws {
        accessToken = nil
        refreshToken = nil
        expiry = nil
    }
}

private func validMemoryTokenStore() -> MemoryYouTubeTokenStore {
    MemoryYouTubeTokenStore(
        accessToken: "valid-access",
        refreshToken: "refresh-token",
        expiry: .distantFuture
    )
}

private actor SuspendingYouTubeAPITransport: YouTubeAPITransport {
    private var started = false
    private(set) var observedCancellation = false

    func response(for request: URLRequest) async throws -> YouTubeAPIResponse {
        started = true
        do {
            try await Task.sleep(for: .seconds(30))
            return YouTubeAPIResponse(data: Data(#"{"items":[]}"#.utf8), statusCode: 200)
        } catch {
            observedCancellation = true
            throw error
        }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }
}

private actor MockYouTubeAPITransport: YouTubeAPITransport {
    private var responses: [YouTubeAPIResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [YouTubeAPIResponse]) {
        self.responses = responses
    }

    var requestCount: Int { requests.count }

    func response(for request: URLRequest) async throws -> YouTubeAPIResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw YouTubeError.invalidResponse
        }
        return responses.removeFirst()
    }
}

private func broadcast(
    id: String,
    title: String,
    status: String,
    scheduledStartTime: String? = nil,
    actualStartTime: String? = nil,
    publishedAt: String? = nil
) -> YouTubeBroadcast {
    YouTubeBroadcast(
        id: id,
        title: title,
        privacyStatus: "unlisted",
        boundStreamId: "shared-stream",
        scheduledStartTime: scheduledStartTime,
        actualStartTime: actualStartTime,
        publishedAt: publishedAt,
        lifeCycleStatus: status,
        enableDvr: true,
        latencyPreference: "normal",
        enableMonitorStream: false,
        broadcastStreamDelayMs: 0,
        enableEmbed: true,
        recordFromStart: true,
        enableAutoStart: true,
        enableAutoStop: true
    )
}

private func streamItem(
    id: String,
    key: String,
    type: String,
    address: String,
    backupAddress: String? = nil,
    publishedAt: String? = nil
) -> [String: Any] {
    var ingestionInfo: [String: Any] = [
        "streamName": key,
        "ingestionAddress": address,
    ]
    if let backupAddress {
        ingestionInfo["backupIngestionAddress"] = backupAddress
    }
    var item: [String: Any] = [
        "id": id,
        "cdn": [
            "ingestionType": type,
            "ingestionInfo": ingestionInfo,
        ],
    ]
    if let publishedAt {
        item["snippet"] = ["publishedAt": publishedAt]
    }
    return item
}

private func streamsResponse(_ items: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["items": items], options: [.sortedKeys])
}
