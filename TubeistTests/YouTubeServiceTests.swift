//
//  YouTubeServiceTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct YouTubeServiceTests {
    @Test(arguments: ["42", "\"42\"", "null", "\"invalid\"", "-1"]) @MainActor
    func viewerCountsAreOptionalAndPinnedToTheSession(value: String) async throws {
        let body = "{\"items\":[{\"id\":\"session-broadcast\",\"liveStreamingDetails\":{\"concurrentViewers\":\(value)}}]}"
        let transport = MockYouTubeAPITransport(responses: [.init(data: Data(body.utf8), statusCode: 200)])
        let store = validMemoryTokenStore()
        let service = YouTubeService(transport: transport, tokenStore: store, discoveryCache: YouTubeDiscoveryCache())
        let target = YouTubeHealthTarget(streamID: "session-stream", broadcastID: "session-broadcast",
            authorizationScope: YouTubeDiscoveryCache.scope(refreshToken: "refresh-token"))
        let count = try await service.fetchConcurrentViewers(target: target)
        #expect(count == (value.contains("42") ? 42 : nil))
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].url?.path == "/youtube/v3/videos")
        #expect(queryItems(in: requests[0]).contains(URLQueryItem(name: "id", value: target.broadcastID)))
        store.refreshToken = "other-account"
        await #expect(throws: YouTubeError.notSignedIn) { try await service.fetchConcurrentViewers(target: target) }
        #expect(await transport.requests.count == 1)
    }

    @Test @MainActor func shutdownObservesOnlyTheOriginalBroadcastAndAccount() async throws {
        let transport = MockYouTubeAPITransport(responses: [.init(
            data: Data(#"{"items":[{"id":"session-broadcast","status":{"lifeCycleStatus":"complete"}}]}"#.utf8), statusCode: 200)])
        let store = validMemoryTokenStore()
        let service = YouTubeService(transport: transport, tokenStore: store, discoveryCache: YouTubeDiscoveryCache())
        let target = YouTubeHealthTarget(streamID: "session-stream", broadcastID: "session-broadcast",
            authorizationScope: YouTubeDiscoveryCache.scope(refreshToken: "refresh-token"))
        #expect(try await service.fetchBroadcastStatus(target: target) == "complete")
        store.refreshToken = "another-account"
        await #expect(throws: YouTubeError.notSignedIn) { try await service.fetchBroadcastStatus(target: target) }
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].httpMethod == "GET")
        #expect(queryItems(in: requests[0]).contains(URLQueryItem(name: "id", value: target.broadcastID)))
    }

    @Test(arguments: ["1800000000", "\"1800000000\""]) @MainActor
    func readsHealthForOnlyThePinnedStreamAndDecodesGoogleTimestamps(timestamp: String) async throws {
        let body = """
        {"items":[{"id":"session-stream","status":{"streamStatus":"active","healthStatus":{
        "status":"bad","lastUpdateTimeSeconds":\(timestamp),"configurationIssues":[{
        "type":"noAudioStream","severity":"error","reason":"Check audio","description":"Missing audio; valid-access refresh-token"}]}}}]}
        """
        let transport = MockYouTubeAPITransport(responses: [.init(data: Data(body.utf8), statusCode: 200)])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
        let target = YouTubeHealthTarget(streamID: "session-stream", broadcastID: "session-broadcast",
            authorizationScope: YouTubeDiscoveryCache.scope(refreshToken: "refresh-token"))
        let health = try await service.fetchIngestHealth(target: target)
        #expect(health.streamStatus == "active")
        #expect(health.healthStatus?.lastUpdateTimeSeconds == 1_800_000_000)
        #expect(health.healthStatus?.configurationIssues?.first?.severity == "error")
        #expect(health.healthStatus?.configurationIssues?.first?.description == "Missing audio; [redacted] [redacted]")
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].url?.path == "/youtube/v3/liveStreams")
        #expect(Set(queryItems(in: requests[0])) == Set([
            URLQueryItem(name: "part", value: "status"), URLQueryItem(name: "id", value: "session-stream")]))
    }

    @Test @MainActor func healthLookupRejectsAccountChangesAndWrongStreamResponses() async throws {
        let transport = MockYouTubeAPITransport(responses: [.init(
            data: Data(#"{"items":[{"id":"wrong-stream","status":{"streamStatus":"active"}}]}"#.utf8), statusCode: 200)])
        let store = validMemoryTokenStore()
        let service = YouTubeService(transport: transport, tokenStore: store, discoveryCache: YouTubeDiscoveryCache())
        let target = YouTubeHealthTarget(streamID: "session-stream", broadcastID: "session-broadcast",
            authorizationScope: YouTubeDiscoveryCache.scope(refreshToken: "refresh-token"))
        await #expect(throws: YouTubeError.invalidResponse) { try await service.fetchIngestHealth(target: target) }
        store.refreshToken = "another-account"
        await #expect(throws: YouTubeError.notSignedIn) { try await service.fetchIngestHealth(target: target) }
        #expect(await transport.requests.count == 1)
    }

    @Test @MainActor func healthLookupRefreshesExpiredAuthorizationAndStillUsesTheSameStream() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            .init(data: Data(#"{"error":{"message":"expired"}}"#.utf8), statusCode: 401),
            .init(data: Data(#"{"access_token":"new-access","expires_in":3600,"token_type":"Bearer"}"#.utf8), statusCode: 200),
            .init(data: Data(#"{"items":[{"id":"session-stream","status":{"streamStatus":"active","healthStatus":{"status":"good"}}}]}"#.utf8), statusCode: 200)
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
        let target = YouTubeHealthTarget(streamID: "session-stream", broadcastID: "session-broadcast",
            authorizationScope: YouTubeDiscoveryCache.scope(refreshToken: "refresh-token"))
        #expect(try await service.fetchIngestHealth(target: target).healthStatus?.status == "good")
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests.first?.url == requests.last?.url)
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
    }

    @Test @MainActor
    func completesOnlyTheBroadcastCapturedAtStart() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            .init(data: Data(#"{"id":"session-broadcast","status":{"lifeCycleStatus":"complete"}}"#.utf8), statusCode: 200)
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
        let target = YouTubeBroadcastCompletionTarget(
            id: "session-broadcast", authorizationScope: YouTubeDiscoveryCache.scope(refreshToken: "refresh-token")
        )
        try await service.completeBroadcastAfterUpload(target, deadline: .now.advanced(by: .seconds(1)))
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].httpMethod == "POST")
        #expect(queryItems(in: requests[0]).contains(URLQueryItem(name: "id", value: target.id)))
        #expect(queryItems(in: requests[0]).contains(URLQueryItem(name: "broadcastStatus", value: "complete")))
    }

    @Test(arguments: ["complete", "live"]) @MainActor
    func completionConfirmsStatusWhenAutoStopRacesTheTransition(status: String) async throws {
        let transport = MockYouTubeAPITransport(responses: [
            .init(data: Data(#"{"error":{"message":"redundant transition"}}"#.utf8), statusCode: 403),
            .init(data: Data("{\"items\":[{\"id\":\"session-broadcast\",\"status\":{\"lifeCycleStatus\":\"\(status)\"}}]}".utf8), statusCode: 200)
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
        let target = YouTubeBroadcastCompletionTarget(
            id: "session-broadcast", authorizationScope: YouTubeDiscoveryCache.scope(refreshToken: "refresh-token")
        )
        if status == "complete" {
            try await service.completeBroadcastAfterUpload(target, deadline: .now.advanced(by: .seconds(1)))
        } else {
            await #expect(throws: YouTubeError.apiError(403, "redundant transition")) {
                try await service.completeBroadcastAfterUpload(target, deadline: .now.advanced(by: .seconds(1)))
            }
        }
        #expect(await transport.requests.map(\.httpMethod) == ["POST", "GET"])
    }

    @Test @MainActor
    func completionRejectsAnAccountChangeWithoutSendingARequest() async throws {
        let transport = MockYouTubeAPITransport(responses: [])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
        let target = YouTubeBroadcastCompletionTarget(
            id: "old-broadcast", authorizationScope: YouTubeDiscoveryCache.scope(refreshToken: "different-account")
        )
        await #expect(throws: YouTubeError.notSignedIn) {
            try await service.completeBroadcastAfterUpload(target, deadline: .now.advanced(by: .seconds(1)))
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test(arguments: [false, true], [false, true]) @MainActor
    func completionCanCancelBothAPIAndTokenRefresh(refreshRequired: Bool, cancelCaller: Bool) async throws {
        let transport = SuspendingYouTubeAPITransport()
        let store = validMemoryTokenStore()
        if refreshRequired { store.expiry = .distantPast }
        let service = YouTubeService(transport: transport, tokenStore: store, discoveryCache: YouTubeDiscoveryCache())
        let target = YouTubeBroadcastCompletionTarget(
            id: "session-broadcast", authorizationScope: YouTubeDiscoveryCache.scope(refreshToken: "refresh-token")
        )
        let start = ContinuousClock.now
        let completion = Task {
            try await service.completeBroadcastAfterUpload(
                target, deadline: start.advanced(by: cancelCaller ? .seconds(30) : .seconds(1))
            )
        }
        if cancelCaller {
            await transport.waitUntilStarted()
            completion.cancel()
        }
        await #expect(throws: CancellationError.self) {
            try await completion.value
        }
        #expect(start.duration(to: .now) < .seconds(5))
        #expect(await transport.observedCancellation)
    }

    @Test func cancellationClassificationDoesNotSuppressRealFailures() {
        #expect(YouTubeDiagnostics.isCancellation(CancellationError()))
        #expect(YouTubeDiagnostics.isCancellation(URLError(.cancelled)))
        #expect(YouTubeDiagnostics.isCancellation(NSError(
            domain: NSURLErrorDomain, code: NSURLErrorCancelled
        )))
        #expect(YouTubeDiagnostics.failure(CancellationError()) == "cancelled")
        #expect(YouTubeDiagnostics.failure(URLError(.cancelled)) == "cancelled")

        #expect(!YouTubeDiagnostics.isCancellation(URLError(.timedOut)))
        #expect(!YouTubeDiagnostics.isCancellation(YouTubeError.apiError(500, "Internal error")))
        #expect(!YouTubeDiagnostics.isCancellation(NSError(
            domain: "unrelated", code: NSURLErrorCancelled
        )))
        #expect(YouTubeDiagnostics.failure(YouTubeError.apiError(500, "Internal error")) == "HTTP 500")
    }

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

    @Test func reusesAnUnconsumedReadyBroadcastBeforeCreatingAnotherSuccessor() {
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

        let selected = YouTubeBroadcastDiscovery.selectCurrentOrUpcoming(
            from: [oldReady, recentComplete, revoked]
        )

        #expect(selected?.id == "old-ready")
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

        let selected = YouTubeBroadcastDiscovery.selectCurrentOrUpcoming(
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

        let selected = YouTubeBroadcastDiscovery.selectCurrentOrUpcoming(
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
            tokenStore: store, discoveryCache: YouTubeDiscoveryCache(),
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
                data: Data(#"{"items":[{"id":"one","status":{"lifeCycleStatus":"ready"}},{"id":"two","status":{"lifeCycleStatus":"testing"}}]}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"two","status":{"lifeCycleStatus":"testing"}},{"id":"one","status":{"lifeCycleStatus":"ready"}}]}"#.utf8),
                statusCode: 200
            ),
        ])
        let service = YouTubeService(
            transport: transport,
            tokenStore: store, discoveryCache: YouTubeDiscoveryCache(),
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
        let service = YouTubeService(transport: transport, tokenStore: store, discoveryCache: YouTubeDiscoveryCache())

        let playlists = try await service.listPlaylists()

        #expect(playlists.map(\.id) == ["p1", "p2"])
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(URLComponents(url: try #require(requests[1].url), resolvingAgainstBaseURL: false)?
            .queryItems?.contains(URLQueryItem(name: "pageToken", value: "page-2")) == true)
    }

    @Test @MainActor
    func plannedListReturnsTodaysChannelMatchesButNotTubeistsOwn() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = ISO8601DateFormatter().string(from: now)
        let tomorrow = ISO8601DateFormatter().string(from: now.addingTimeInterval(86_400))
        func item(_ id: String, stream: String, start: String) -> [String: Any] {
            ["id": id, "snippet": ["title": id, "scheduledStartTime": start],
             "status": ["privacyStatus": "unlisted", "lifeCycleStatus": "ready"],
             "contentDetails": ["boundStreamId": stream]]
        }
        let page = YouTubeAPIResponse(data: try JSONSerialization.data(withJSONObject: ["items": [
            item("match-today", stream: "stream-1", start: today),
            item("other-stream", stream: "stream-2", start: today),
            item("match-tomorrow", stream: "stream-1", start: tomorrow),
            item("created", stream: "stream-1", start: today),
        ]]), statusCode: 200)
        let titled = YouTubeAPIResponse(data: Data(#"{"items":[{"id":"stream-1","snippet":{"title":"Court 1"},"cdn":{"ingestionType":"hls","ingestionInfo":{"streamName":"test-key","ingestionAddress":"https://a.upload.youtube.com/http_upload_hls?cid=test-key&file="}}}]}"#.utf8), statusCode: 200)
        // selectedBroadcast: active, upcoming, stream lookup; then title lookup, key titles and the planned list.
        let transport = MockYouTubeAPITransport(responses: [emptyYouTubePage(), page, titled, titled, titled, page])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(),
                                     discoveryCache: createdBroadcastCache("created"), now: { now })

        let result = try await service.loadPlannedBroadcasts(forStreamKey: "test-key", calendar: calendar)

        #expect(result.broadcasts.map(\.id) == ["match-today", "other-stream"])
        #expect(result.streamTitle == "Court 1")
        let requests = await transport.requests
        #expect(queryItems(in: try #require(requests.last)).contains(URLQueryItem(name: "broadcastStatus", value: "upcoming")))
    }

    @Test @MainActor
    func plannedListMarksMatchesThatNeedTheirOwnKey() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = ISO8601DateFormatter().string(from: now)
        func item(_ id: String, stream: String) -> [String: Any] {
            ["id": id, "snippet": ["title": id, "scheduledStartTime": today],
             "status": ["privacyStatus": "unlisted", "lifeCycleStatus": "ready"],
             "contentDetails": ["boundStreamId": stream]]
        }
        let page = YouTubeAPIResponse(data: try JSONSerialization.data(withJSONObject: ["items": [
            item("created", stream: "stream-1"),
            item("shared-a", stream: "stream-2"), item("shared-b", stream: "stream-2"),
            item("alone", stream: "stream-3"),
        ]]), statusCode: 200)
        let titled = YouTubeAPIResponse(data: Data(#"{"items":[{"id":"stream-1","snippet":{"title":"Court 1"},"cdn":{"ingestionType":"hls","ingestionInfo":{"streamName":"test-key","ingestionAddress":"https://a.upload.youtube.com/http_upload_hls?cid=test-key&file="}}},{"id":"stream-2","snippet":{"title":"Tubeist match 1"},"cdn":{"ingestionType":"hls","ingestionInfo":{"streamName":"key-2","ingestionAddress":"https://a.upload.youtube.com/http_upload_hls?cid=key-2&file="}}},{"id":"stream-3","snippet":{"title":"Tubeist match 2"},"cdn":{"ingestionType":"hls","ingestionInfo":{"streamName":"key-3","ingestionAddress":"https://a.upload.youtube.com/http_upload_hls?cid=key-3&file="}}}]}"#.utf8), statusCode: 200)
        let transport = MockYouTubeAPITransport(responses: [emptyYouTubePage(), page, titled, titled, titled, page])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(),
                                     discoveryCache: createdBroadcastCache("created"), now: { now })

        let result = try await service.loadPlannedBroadcasts(forStreamKey: "test-key", calendar: calendar)

        #expect(result.needsOwnKey == ["shared-a", "shared-b"])
        #expect(result.keyTitles == ["stream-1": "Court 1", "stream-2": "Tubeist match 1", "stream-3": "Tubeist match 2"])
    }

    @Test @MainActor
    func membershipReturnsFirstPlaylistContainingTheBroadcast() async throws {
        let playlists = ["p1", "p2", "p3"].map { YouTubePlaylist(id: $0, title: $0) }
        let hit = YouTubeAPIResponse(data: Data(#"{"items":[{"id":"item-9"}]}"#.utf8), statusCode: 200)
        let transport = MockYouTubeAPITransport(responses: [emptyYouTubePage(), hit, emptyYouTubePage()])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())

        let found = try await service.playlistMembership(videoId: "video", among: playlists)

        #expect(found == YouTubePlaylistMembership(playlistId: "p2", itemId: "item-9"))
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(queryItems(in: requests[1]).contains(URLQueryItem(name: "videoId", value: "video")))

        let none = MockYouTubeAPITransport(responses: [emptyYouTubePage(), emptyYouTubePage(), emptyYouTubePage()])
        let other = YouTubeService(transport: none, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
        #expect(try await other.playlistMembership(videoId: "video", among: playlists) == nil)
        #expect(await none.requests.count == 3)
    }

    @Test @MainActor
    func removeFromPlaylistSendsDeleteWithItemID() async throws {
        let transport = MockYouTubeAPITransport(responses: [.init(data: Data(), statusCode: 204)])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())

        try await service.removeFromPlaylist(itemId: "item-9")

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/youtube/v3/playlistItems")
        #expect(queryItems(in: request) == [URLQueryItem(name: "id", value: "item-9")])
    }

    @Test @MainActor
    func thumbnailDownloadSendsNoAuthorizationHeader() async throws {
        let body = Data([1, 2, 3])
        let transport = MockYouTubeAPITransport(responses: [
            .init(data: body, statusCode: 200),
            .init(data: Data(count: 2_000_001), statusCode: 200),
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())

        let data = try await service.downloadThumbnail(from: "https://i.ytimg.com/vi/x/maxres.jpg")

        #expect(data == body)
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpMethod == "GET")
        await #expect(throws: YouTubeError.thumbnailTooLarge) {
            _ = try await service.downloadThumbnail(from: "https://i.ytimg.com/vi/x/maxres.jpg")
        }
    }

    @Test(arguments: [200, 500]) @MainActor
    func broadcastLookupPreservesOpaqueTokensThroughFourPages(_ lastStatus: Int) async throws {
        let pageTokens = ["page-2", "page/3%2B=", "page+4&part=bad#? é"]
        var responses = [emptyYouTubePage()]
        responses += try pageTokens.enumerated().map { index, pageToken in
            YouTubeAPIResponse(data: try JSONSerialization.data(withJSONObject: [
                "items": (0..<50).map { ["id": "unbound-\(index)-\($0)"] },
                "nextPageToken": pageToken,
            ]), statusCode: 200)
        }
        responses.append(lastStatus == 200 ? currentBroadcastPage() : .init(
            data: Data(#"{"error":{"message":"Internal error encountered.","status":"INTERNAL","errors":[{"domain":"global","reason":"backendError"}]}}"#.utf8),
            statusCode: 500
        ))
        if lastStatus == 200 { responses.append(matchingStreamPage()) }
        let captured = CapturedYouTubeDiagnostics()
        let transport = MockYouTubeAPITransport(responses: responses)
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: createdBroadcastCache("ready"), diagnostics: captured.diagnostics)

        if lastStatus == 200 {
            let endpoint = try await service.findHLSIngestionEndpoint(forStreamKey: "test-key")
            let expectedURL = try #require(URL(string: "https://a.upload.youtube.com/http_upload_hls?cid=test-key&file="))
            #expect(endpoint == (try YouTubeHLSEndpoint(expectedURL)))
        } else {
            await #expect(throws: YouTubeError.apiError(500, "Internal error encountered.")) {
                _ = try await service.findHLSIngestionEndpoint(forStreamKey: "test-key")
            }
            #expect(captured.text.contains("liveBroadcasts.list: page 4 failed after 150 items"))
            #expect(captured.text.contains("page token present=true; token contains plus=true; HTTP 500"))
        }

        let requests = await transport.requests
        #expect(requests.count == (lastStatus == 200 ? 6 : 5))
        // The first request checks active broadcasts; these four pages are upcoming.
        let pages = requests.filter { $0.url?.path.hasSuffix("/liveBroadcasts") == true }.dropFirst()
        #expect(pages.count == 4)
        for (index, request) in pages.enumerated() {
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer valid-access")
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            // Decode like a form-style server: a literal + means a space.
            let query = try #require(components.percentEncodedQuery)
            var decoded = URLComponents()
            decoded.percentEncodedQuery = query.replacingOccurrences(of: "+", with: "%20")
            let items = try #require(decoded.queryItems)
            #expect(items.filter { $0.name == "part" }.map(\.value) == ["snippet,contentDetails,status"])
            #expect(items.filter { $0.name == "broadcastStatus" }.map(\.value) == ["upcoming"])
            #expect(items.filter { $0.name == "broadcastType" }.map(\.value) == ["all"])
            #expect(items.filter { $0.name == "maxResults" }.map(\.value) == ["50"])
            let expectedTokens: [String?] = index == 0 ? [] : [pageTokens[index - 1]]
            #expect(items.filter { $0.name == "pageToken" }.map(\.value) == expectedTokens)
            #expect(items.count == (index == 0 ? 4 : 5))
        }
        #expect(!service.isLoading)
        for token in pageTokens { #expect(!captured.text.contains(token)) }
        #expect(!captured.text.contains("valid-access"))
        #expect(!captured.text.contains("test-key"))
    }

    @Test(arguments: ["active", "upcoming"]) @MainActor
    func matchingFirstPageStopsBeforeFetchingAnotherPage(_ status: String) async throws {
        let lifecycle = status == "active" ? "live" : "ready"
        var responses = status == "active" ? [] : [emptyYouTubePage()]
        responses += [
            currentBroadcastPage(status: lifecycle, nextPageToken: "must-not-fetch"),
            matchingStreamPage(),
            .init(data: Data(), statusCode: 500),
        ]
        let transport = MockYouTubeAPITransport(responses: responses)
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: createdBroadcastCache("ready"))
        let found = try await service.findBroadcastForStreamKey("test-key")
        #expect(found.id == "ready")
        #expect(found.lifeCycleStatus == lifecycle)
        let requests = await transport.requests
        #expect(requests.count == (status == "active" ? 2 : 3))
        let statuses = requests.flatMap { queryItems(in: $0).filter { $0.name == "broadcastStatus" }.compactMap(\.value) }
        #expect(statuses == (status == "active" ? ["active"] : ["active", "upcoming"]))
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        #expect(!requests.contains { queryItems(in: $0).contains { $0.name == "pageToken" || $0.name == "mine" } })
        let streamRequest = try #require(requests.last)
        #expect(streamRequest.url?.path == "/youtube/v3/liveStreams")
        #expect(queryItems(in: streamRequest).filter { $0.name == "id" }.map(\.value) == ["stream-1"])
    }

    @Test @MainActor
    func discoveryContinuesOnlyWhenThePageHasNoMatchingKey() async throws {
        let wrongStream = YouTubeAPIResponse(data: try streamsResponse([
            streamItem(id: "stream-1", key: "other-key", type: "hls",
                       address: "https://a.upload.youtube.com/http_upload_hls?cid=other-key&file=")
        ]), statusCode: 200)
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(),
            currentBroadcastPage(nextPageToken: "second+page"), wrongStream,
            currentBroadcastPage(nextPageToken: "must-not-fetch"), matchingStreamPage(),
            .init(data: Data(), statusCode: 500),
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: createdBroadcastCache("ready"))
        #expect(try await service.findBroadcastForStreamKey("test-key").id == "ready")
        let requests = await transport.requests
        #expect(requests.count == 5)
        #expect(requests.map { $0.url?.lastPathComponent } == ["liveBroadcasts", "liveBroadcasts", "liveStreams", "liveBroadcasts", "liveStreams"])
        #expect(queryItems(in: requests[3]).filter { $0.name == "pageToken" }.map(\.value) == ["second+page"])
    }

    @Test @MainActor
    func broadcastMutationsUseExpectedMethodsAndTypedResponses() async throws {
        let store = validMemoryTokenStore()
        let transport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(data: Data(#"{"id":"broadcast-1"}"#.utf8), statusCode: 200),
            YouTubeAPIResponse(
                data: Data(#"{"id":"broadcast-1","status":{"lifeCycleStatus":"complete"}}"#.utf8),
                statusCode: 200
            ),
        ])
        let service = YouTubeService(transport: transport, tokenStore: store, discoveryCache: YouTubeDiscoveryCache())

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
            tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache()
        )
        try await existingService.addToPlaylist(playlistId: "playlist", videoId: "video")
        #expect(await existingTransport.requestCount == 1)

        let insertionTransport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(data: Data(#"{"items":[]}"#.utf8), statusCode: 200),
            YouTubeAPIResponse(data: Data(#"{"id":"playlist-item"}"#.utf8), statusCode: 200),
        ])
        let insertionService = YouTubeService(
            transport: insertionTransport,
            tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache()
        )
        try await insertionService.addToPlaylist(playlistId: "playlist", videoId: "video")
        let insertionRequests = await insertionTransport.requests
        #expect(insertionRequests[0].httpMethod == "GET")
        #expect(insertionRequests[1].httpMethod == "POST")
    }

    @Test(arguments: [false, true]) @MainActor
    func statusLookupDoesNotCreateBroadcastsOrFetchCompletedHistory(_ staleCompletedResult: Bool) async throws {
        let page = staleCompletedResult ? currentBroadcastPage(status: "complete") : emptyYouTubePage()
        let transport = MockYouTubeAPITransport(responses: [page, page, matchingStreamPage()])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
        await #expect(throws: YouTubeError.noBroadcastFound) {
            _ = try await service.findBroadcastForStreamKey("test-key")
        }
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.flatMap { queryItems(in: $0).filter { $0.name == "broadcastStatus" }.compactMap(\.value) } == ["active", "upcoming"])
        #expect(!service.isLoading)
    }

    @Test @MainActor
    func firstTimeSetupCreatesAReusableHLSKeyAndAReadOnlySettingsDraft() async throws {
        let captured = CapturedYouTubeDiagnostics()
        let cache = YouTubeDiscoveryCache()
        let transport = MockYouTubeAPITransport(responses: [
            streamResourceResponse(),
            emptyYouTubePage(), matchingStreamPage(), emptyYouTubePage(), emptyYouTubePage(), emptyYouTubePage()
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: cache, diagnostics: captured.diagnostics)
        let stream = try await service.setUpStream()
        #expect(stream.id == "stream-1")
        #expect(stream.streamName == "test-key")
        let settings = try await service.loadSettingsConfiguration(forStreamKey: stream.streamName)
        #expect(settings.broadcast.id.isEmpty)
        #expect(settings.broadcast.boundStreamId == stream.id)
        #expect(settings.broadcast.lifeCycleStatus == "draft")
        #expect(settings.broadcast.privacyStatus == "private")
        #expect(settings.broadcast.enableAutoStart)
        #expect(settings.broadcast.selfDeclaredMadeForKids == false)
        let requests = await transport.requests
        #expect(requests.count == 6)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].url?.path.hasSuffix("/liveStreams") == true)
        let body = try #require(JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: Any])
        let cdn = try #require(body["cdn"] as? [String: String])
        #expect(cdn == ["ingestionType": "hls", "resolution": "variable", "frameRate": "variable"])
        #expect((body["contentDetails"] as? [String: Bool])?["isReusable"] == true)
        #expect(requests.dropFirst().allSatisfy { $0.httpMethod == "GET" })
        #expect(!captured.text.contains("test-key"))
    }

    @Test @MainActor
    func setupReusesItsKeyAcrossServiceInstancesAndClearsItOnSignOut() async throws {
        let cache = YouTubeDiscoveryCache()
        let store = validMemoryTokenStore()
        let transport = MockYouTubeAPITransport(responses: [streamResourceResponse(), matchingStreamPage(), streamResourceResponse()])
        let first = YouTubeService(transport: transport, tokenStore: store, discoveryCache: cache)
        let a = try await first.setUpStream()
        let second = YouTubeService(transport: transport, tokenStore: store, discoveryCache: cache)
        let b = try await second.setUpStream()
        #expect(a == b)
        #expect(second.signOut())
        // Another authorization must not reuse identifiers from the old grant.
        let third = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: cache)
        _ = try await third.setUpStream()
        #expect(await transport.requests.map(\.httpMethod) == ["POST", "GET", "POST"])
    }

    @Test @MainActor
    func discoveryCachePersistsOnlyIdentifiersAndIsolatesAccountsAndKeys() async throws {
        let name = "YouTubeDiscoveryTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = validMemoryTokenStore()
        let scope = YouTubeDiscoveryCache.scope(refreshToken: store.refreshToken!)
        let key = YouTubeDiscoveryCache.key(scope: scope, streamKey: "test-key")
        let cache = YouTubeDiscoveryCache(defaults: defaults)
        cache.setID("stream-1", kind: "stream", for: key)
        cache.setID("ready", kind: "createdBroadcast", for: key)
        let restored = YouTubeDiscoveryCache(defaults: defaults)
        let transport = MockYouTubeAPITransport(responses: [matchingStreamPage(), emptyYouTubePage(), currentBroadcastPage()])
        let service = YouTubeService(transport: transport, tokenStore: store, discoveryCache: restored)
        _ = try await service.findBroadcastForStreamKey("test-key")
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(queryItems(in: requests[0]).contains(.init(name: "id", value: "stream-1")))
        #expect(!requests.flatMap { queryItems(in: $0) }.contains(.init(name: "mine", value: "true")))
        let data = try JSONSerialization.data(withJSONObject: defaults.dictionary(forKey: "YouTubeDiscoveryIDs")!)
        let stored = String(decoding: data, as: UTF8.self)
        #expect(!stored.contains("test-key"))
        #expect(!stored.contains("refresh-token"))
        let differentScope = YouTubeDiscoveryCache.scope(refreshToken: "another-account")
        #expect(restored.id("stream", for: YouTubeDiscoveryCache.key(scope: differentScope, streamKey: "test-key")) == nil)
        #expect(restored.id("stream", for: YouTubeDiscoveryCache.key(scope: scope, streamKey: "another-key")) == nil)
    }

    @Test(arguments: [false, true]) @MainActor
    func staleCachedStreamIsReplacedAfterAnExactKeyCheck(_ wrongKey: Bool) async throws {
        let cache = YouTubeDiscoveryCache()
        let key = YouTubeDiscoveryCache.key(scope: YouTubeDiscoveryCache.scope(refreshToken: "refresh-token"), streamKey: "test-key")
        cache.setID("stale-id", kind: "stream", for: key)
        cache.setID("ready", kind: "createdBroadcast", for: key)
        let stale = wrongKey ? YouTubeAPIResponse(data: try streamsResponse([streamItem(id: "stale-id", key: "wrong-key", type: "hls", address: "https://a.upload.youtube.com/http_upload_hls?cid=wrong-key&file=")]), statusCode: 200) : emptyYouTubePage()
        let transport = MockYouTubeAPITransport(responses: [stale, emptyYouTubePage(), currentBroadcastPage(), matchingStreamPage()])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: cache)
        _ = try await service.findBroadcastForStreamKey("test-key")
        #expect(await transport.requestCount == 4)
        #expect(cache.id("stream", for: key) == "stream-1")
    }

    @Test @MainActor
    func standaloneKeyLookupStopsBeforeAFailingLaterPage() async throws {
        var match = try #require(JSONSerialization.jsonObject(with: matchingStreamPage().data) as? [String: Any])
        match["nextPageToken"] = "never-fetch"
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(), emptyYouTubePage(), .init(data: try JSONSerialization.data(withJSONObject: match), statusCode: 200),
            .init(data: Data(), statusCode: 500)
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
        _ = try await service.findHLSIngestionEndpoint(forStreamKey: "test-key")
        #expect(await transport.requestCount == 3)
    }

    @Test @MainActor
    func manualEndingDisablesAutoStopOnAnExistingBroadcastDespiteSavedPreferences() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(), broadcastPageResponse(status: "ready", bound: true, autoStop: true),
            matchingStreamPage(), broadcastResourceResponse(status: "ready", bound: true, autoStop: false)
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: createdBroadcastCache("new-event"))
        let result = try await service.prepareForStreaming(
            streamKey: "test-key", preferences: setupPreferences(), endingPolicy: .manualDiagnostic
        )
        #expect(!result.broadcast.enableAutoStop)
        #expect(result.completionTarget == nil)
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "GET", "PUT"])
        #expect(requests.last?.httpBody?.range(of: Data(#""enableAutoStop":false"#.utf8)) != nil)
    }

    @Test @MainActor
    func manualEndingCreatesANewBroadcastWithAutoStopAlreadyDisabled() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(), emptyYouTubePage(), matchingStreamPage(),
            broadcastResourceResponse(status: "created", bound: false, autoStop: false),
            broadcastResourceResponse(status: "ready", bound: true, autoStop: false)
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
        let result = try await service.prepareForStreaming(
            streamKey: "test-key", preferences: setupPreferences(), endingPolicy: .manualDiagnostic
        )
        #expect(!result.broadcast.enableAutoStop)
        #expect(result.completionTarget == nil)
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "GET", "POST", "POST"])
        #expect(requests[3].httpBody?.range(of: Data(#""enableAutoStop":false"#.utf8)) != nil)
    }

    @Test(arguments: [false, true]) @MainActor
    func manualEndingRequiresServerConfirmationThatAutoStopIsDisabled(omitsConfirmation: Bool) async throws {
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(), broadcastPageResponse(status: "ready", bound: true, autoStop: true),
            matchingStreamPage(),
            broadcastResourceResponse(status: "ready", bound: true, autoStop: omitsConfirmation ? nil : true)
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
        await #expect(throws: YouTubeError.invalidResponse) {
            _ = try await service.prepareForStreaming(streamKey: "test-key", endingPolicy: .manualDiagnostic)
        }
    }

    @Test @MainActor
    func startCreatesAndBindsFromSavedPreferencesWithoutACompletedTemplate() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(), emptyYouTubePage(), matchingStreamPage(),
            broadcastResourceResponse(status: "created", bound: false), broadcastResourceResponse(status: "ready", bound: true)
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache(), now: { fixedNow })
        let preferences = setupPreferences()
        let result = try await service.prepareForStreaming(streamKey: "test-key", preferences: preferences)
        #expect(result.broadcast.id == "new-event")
        #expect(result.broadcast.boundStreamId == "stream-1")
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "GET", "POST", "POST"])
        let body = try #require(JSONSerialization.jsonObject(with: requests[3].httpBody!) as? [String: Any])
        let snippet = try #require(body["snippet"] as? [String: String])
        #expect(snippet["title"] == preferences.title)
        #expect(ISO8601DateFormatter().date(from: snippet["scheduledStartTime"]!) == fixedNow.addingTimeInterval(10))
        let status = try #require(body["status"] as? [String: Any])
        #expect(status["privacyStatus"] as? String == "private")
        #expect(status["selfDeclaredMadeForKids"] as? Bool == false)
        let details = try #require(body["contentDetails"] as? [String: Any])
        #expect(details["enableAutoStart"] as? Bool == true)
        #expect(details["enableAutoStop"] as? Bool == true)
        #expect(queryItems(in: requests[4]).contains(.init(name: "streamId", value: "stream-1")))
        #expect(requests[4].httpBody?.isEmpty == true)
    }

    @Test @MainActor
    func newStreamStartStillReusesTheBroadcastTubeistCreated() async throws {
        let cache = createdBroadcastCache("new-event")
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(), studioPlannedPage(status: "ready", id: "new-event"), matchingStreamPage(),
            broadcastResourceResponse(status: "ready", bound: true)
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: cache)
        let preparation = try await service.prepareForStreaming(streamKey: "test-key", preferences: setupPreferences())
        #expect(preparation.broadcast.id == "new-event")
        let requests = await transport.requests
        #expect(!requests.contains { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/liveBroadcasts") == true })
    }

    @Test @MainActor
    func liveBroadcastIsStillResumedRegardlessOfOrigin() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            studioPlannedPage(status: "liveStarting", id: "active"), matchingStreamPage(),
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
        await #expect(throws: YouTubeError.broadcastNotReady("starting live stream")) {
            _ = try await service.prepareForStreaming(streamKey: "test-key", preferences: setupPreferences())
        }
    }

    @Test
    func upcomingPolicyOnlyAdmitsTheNamedUpcomingBroadcast() {
        let ready = broadcast(id: "a", title: "A", status: "ready")
        let live = broadcast(id: "b", title: "B", status: "live")
        #expect(YouTubeBroadcastDiscovery.selectCurrentOrUpcoming(from: [ready], upcoming: .only(nil)) == nil)
        #expect(YouTubeBroadcastDiscovery.selectCurrentOrUpcoming(from: [ready], upcoming: .only("x")) == nil)
        #expect(YouTubeBroadcastDiscovery.selectCurrentOrUpcoming(from: [ready], upcoming: .only("a"))?.id == "a")
        #expect(YouTubeBroadcastDiscovery.selectCurrentOrUpcoming(from: [ready, live], upcoming: .only(nil))?.id == "b")
    }

    @Test @MainActor
    func failedBindResumesTheSameBroadcastOnRetry() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(), emptyYouTubePage(), matchingStreamPage(),
            broadcastResourceResponse(status: "created", bound: false), .init(data: Data(), statusCode: 500),
            matchingStreamPage(), emptyYouTubePage(), emptyYouTubePage(),
            broadcastPageResponse(status: "created", bound: false), broadcastResourceResponse(status: "ready", bound: true)
        ])
        let cache = YouTubeDiscoveryCache()
        let first = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: cache)
        await #expect(throws: YouTubeError.apiError(500, "The request was rejected")) {
            _ = try await first.prepareForStreaming(streamKey: "test-key", preferences: setupPreferences())
        }
        let second = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: cache)
        let result = try await second.prepareForStreaming(streamKey: "test-key", preferences: setupPreferences())
        #expect(result.broadcast.id == "new-event")
        let requests = await transport.requests
        #expect(requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/liveBroadcasts") == true }.count == 1)
        #expect(requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/bind") == true }.count == 2)
    }

    @Test @MainActor
    func aCompletedRememberedBroadcastAllowsANewEventWithoutHistoryPagination() async throws {
        let cache = YouTubeDiscoveryCache()
        let key = YouTubeDiscoveryCache.key(scope: YouTubeDiscoveryCache.scope(refreshToken: "refresh-token"), streamKey: "test-key")
        cache.setID("stream-1", kind: "stream", for: key)
        cache.setID("new-event", kind: "createdBroadcast", for: key)
        let transport = MockYouTubeAPITransport(responses: [
            matchingStreamPage(), emptyYouTubePage(), emptyYouTubePage(), broadcastPageResponse(status: "complete", bound: true),
            broadcastResourceResponse(status: "created", bound: false), broadcastResourceResponse(status: "ready", bound: true)
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: cache)
        _ = try await service.prepareForStreaming(streamKey: "test-key", preferences: setupPreferences())
        let requests = await transport.requests
        #expect(requests.count == 6)
        #expect(requests.flatMap { queryItems(in: $0).filter { $0.name == "broadcastStatus" }.compactMap(\.value) } == ["active", "upcoming"])
        #expect(queryItems(in: requests[3]).contains(.init(name: "id", value: "new-event")))
    }

    @Test @MainActor
    func concurrentStartPreflightsShareOneCreation() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(), emptyYouTubePage(), matchingStreamPage(),
            broadcastResourceResponse(status: "created", bound: false), broadcastResourceResponse(status: "ready", bound: true)
        ])
        let cache = YouTubeDiscoveryCache()
        let first = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: cache)
        let second = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: cache)
        async let a = first.prepareForStreaming(streamKey: "test-key", preferences: setupPreferences())
        async let b = second.prepareForStreaming(streamKey: "test-key", preferences: setupPreferences())
        let results = try await (a, b)
        #expect(results.0 == results.1)
        #expect(await transport.requestCount == 5)
    }

    @Test @MainActor
    func aFailedLookupNeverCreatesAReplacement() async throws {
        let transport = MockYouTubeAPITransport(responses: [.init(data: Data(), statusCode: 500)])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
        await #expect(throws: YouTubeError.apiError(500, "The request was rejected")) {
            _ = try await service.prepareForStreaming(streamKey: "test-key")
        }
        #expect(await transport.requests.map(\.httpMethod) == ["GET"])
    }

    @Test @MainActor
    func cancellationStopsStreamSetupAndClearsLoadingState() async throws {
        let transport = SuspendingYouTubeAPITransport()
        let cache = YouTubeDiscoveryCache()
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: cache)
        let task = Task { try await service.setUpStream() }
        await transport.waitUntilStarted()
        #expect(service.isLoading)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled setup should not return a stream")
        } catch {
            #expect(YouTubeDiagnostics.failure(error) == "cancelled")
        }
        #expect(!service.isLoading)
        #expect(cache.streamSetups.isEmpty)
        #expect(await transport.observedCancellation)
    }

    @Test @MainActor
    func cancellationStopsStreamingPreflightBeforeItCanCreateAnEvent() async throws {
        let transport = SuspendingYouTubeAPITransport()
        let cache = YouTubeDiscoveryCache()
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: cache)
        let task = Task { try await service.prepareForStreaming(streamKey: "test-key") }
        await transport.waitUntilStarted()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled preflight should not return a broadcast")
        } catch {
            #expect(YouTubeDiagnostics.failure(error) == "cancelled")
        }
        #expect(!service.isLoading)
        #expect(cache.preparations.isEmpty)
        #expect(await transport.observedCancellation)
    }

    @Test func savedPreferencesFromBeforeTheAudienceSettingStillDecode() throws {
        let data = try JSONEncoder().encode(setupPreferences())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "selfDeclaredMadeForKids")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let preferences = try JSONDecoder().decode(YouTubeBroadcastPreferences.self, from: legacyData)
        #expect(preferences.title == "Saved title")
        #expect(preferences.selfDeclaredMadeForKids == nil)
    }

    @Test @MainActor
    func streamingPreflightReusesReadyAndRejectsStillActiveBroadcasts() async throws {
        let readyTransport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(),
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"ready","snippet":{"title":"Next"},"status":{"privacyStatus":"unlisted","lifeCycleStatus":"ready"},"contentDetails":{"boundStreamId":"stream-1","enableAutoStop":false}}]}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"stream-1","cdn":{"ingestionType":"hls","ingestionInfo":{"streamName":"test-key","ingestionAddress":"https://a.upload.youtube.com/http_upload_hls?cid=test-key&file="}}}]}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"id":"ready","snippet":{"title":"Next"},"status":{"privacyStatus":"unlisted","lifeCycleStatus":"ready"},"contentDetails":{"boundStreamId":"stream-1","enableAutoStop":true}}"#.utf8),
                statusCode: 200
            ),
        ])
        let readyService = YouTubeService(
            transport: readyTransport,
            tokenStore: validMemoryTokenStore(), discoveryCache: createdBroadcastCache("ready")
        )

        let preparation = try await readyService.prepareForStreaming(streamKey: "test-key")
        #expect(preparation.broadcast.id == "ready")
        #expect(preparation.broadcast.enableAutoStop)
        #expect(preparation.completionTarget != nil)
        let readyRequests = await readyTransport.requests
        #expect(readyRequests.map(\.httpMethod) == ["GET", "GET", "GET", "PUT"])
        #expect(readyRequests[3].httpBody?.range(of: Data(#""enableAutoStop":true"#.utf8)) != nil)
        #expect(!readyRequests.contains { $0.url?.path.hasSuffix("/liveBroadcasts/bind") == true })

        let activeTransport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"active","snippet":{"title":"Previous"},"status":{"privacyStatus":"unlisted","lifeCycleStatus":"liveStarting"},"contentDetails":{"boundStreamId":"stream-1"}}]}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"stream-1","cdn":{"ingestionType":"hls","ingestionInfo":{"streamName":"test-key","ingestionAddress":"https://a.upload.youtube.com/http_upload_hls?cid=test-key&file="}}}]}"#.utf8),
                statusCode: 200
            ),
        ])
        let activeService = YouTubeService(
            transport: activeTransport,
            tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache()
        )

        await #expect(throws: YouTubeError.broadcastNotReady("starting live stream")) {
            _ = try await activeService.prepareForStreaming(streamKey: "test-key")
        }
        #expect(await activeTransport.requestCount == 2)
    }

    @Test @MainActor
    func streamingPreflightAppliesSavedPreferencesWithoutCreatingAnotherBroadcast() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(),
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"ready","snippet":{"title":"Old title","scheduledStartTime":"2026-08-22T10:00:00Z"},"status":{"privacyStatus":"unlisted","lifeCycleStatus":"ready"},"contentDetails":{"boundStreamId":"stream-1","enableDvr":true,"latencyPreference":"normal","monitorStream":{"enableMonitorStream":false,"broadcastStreamDelayMs":0},"enableEmbed":true,"recordFromStart":true,"enableAutoStart":true,"enableAutoStop":true}}]}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"stream-1","cdn":{"ingestionType":"hls","ingestionInfo":{"streamName":"test-key","ingestionAddress":"https://a.upload.youtube.com/http_upload_hls?cid=test-key&file="}}}]}"#.utf8),
                statusCode: 200
            ),
            YouTubeAPIResponse(
                data: Data(#"{"id":"ready","snippet":{"title":"Saved title"},"status":{"privacyStatus":"private","lifeCycleStatus":"ready"},"contentDetails":{"boundStreamId":"stream-1"}}"#.utf8),
                statusCode: 200
            ),
        ])
        let service = YouTubeService(
            transport: transport,
            tokenStore: validMemoryTokenStore(), discoveryCache: createdBroadcastCache("ready")
        )
        let preferences = YouTubeBroadcastPreferences(
            streamId: "stream-1",
            title: "Saved title",
            privacyStatus: "private",
            enableDvr: false,
            latencyPreference: "low",
            enableMonitorStream: false,
            broadcastStreamDelayMs: 0,
            enableEmbed: true,
            recordFromStart: true,
            enableAutoStart: true,
            enableAutoStop: true,
            playlistId: nil
        )

        let preparation = try await service.prepareForStreaming(
            streamKey: "test-key",
            preferences: preferences
        )

        #expect(preparation.broadcast.id == "ready")
        #expect(preparation.broadcast.title == "Saved title")
        #expect(preparation.broadcast.privacyStatus == "private")
        #expect(preparation.broadcast.enableAutoStop)
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "GET", "PUT"])
        #expect(requests[3].httpBody?.range(of: Data(#""enableAutoStop":true"#.utf8)) != nil)
        #expect(!requests.contains { $0.url?.path.hasSuffix("/liveBroadcasts/bind") == true })
    }

    @Test @MainActor
    func thumbnailMutationPreservesBinaryBodyAndMetadata() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(data: Data(), statusCode: 200),
        ])
        let service = YouTubeService(
            transport: transport,
            tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache()
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
    func rejectedThumbnailAndDeletedPlaylistDoNotBlockStart() async throws {
        let captured = CapturedYouTubeDiagnostics()
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(), broadcastPageResponse(status: "ready", bound: true), matchingStreamPage(),
            .init(data: Data(#"{"error":{"message":"Custom thumbnails are not allowed"}}"#.utf8), statusCode: 403),
            .init(data: Data(#"{"error":{"message":"Playlist not found"}}"#.utf8), statusCode: 404),
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(),
                                     discoveryCache: createdBroadcastCache("new-event"), diagnostics: captured.diagnostics)
        var preferences = setupPreferences()
        preferences.playlistId = "deleted-playlist"
        let preparation = try await service.prepareForStreaming(
            streamKey: "test-key", preferences: preferences, thumbnailData: Data([0xFF, 0xD8, 0xFF, 0xD9])
        )
        #expect(preparation.broadcast.id == "new-event")
        #expect(!service.isLoading)
        let requests = await transport.requests
        #expect(requests.count == 5)
        #expect(requests[3].url?.path.hasSuffix("/thumbnails/set") == true)
        #expect(requests[4].url?.path.hasSuffix("/playlistItems") == true)
        let warnings = captured.entries.filter { $0.1 == .warning }.map(\.0)
        #expect(warnings.contains("YouTube thumbnail could not be set (HTTP 403); starting without it"))
        #expect(warnings.contains("YouTube broadcast could not be added to the saved playlist (HTTP 404); starting without it"))
        #expect(!captured.entries.contains { $0.1 == .error })
    }

    @Test @MainActor
    func accountChangeDuringAnOptionalStartStepStillStopsStart() async throws {
        let transport = DeferredYouTubeChannelTransport()
        let store = validMemoryTokenStore()
        let service = YouTubeService(transport: transport, tokenStore: store, discoveryCache: createdBroadcastCache("new-event"))
        let start = Task {
            try await service.prepareForStreaming(
                streamKey: "test-key", preferences: setupPreferences(), thumbnailData: Data([0xFF, 0xD8, 0xFF, 0xD9])
            )
        }
        for response in [emptyYouTubePage(), broadcastPageResponse(status: "ready", bound: true), matchingStreamPage()] {
            await transport.waitUntilStarted()
            await transport.complete(with: response)
        }
        await transport.waitUntilStarted()
        store.refreshToken = "other-account"
        await transport.complete(with: .init(data: Data(), statusCode: 500))
        await #expect(throws: YouTubeError.notSignedIn) { _ = try await start.value }
        #expect(!service.isLoading)
    }

    @Test @MainActor
    func aReusedBroadcastReceivesEachThumbnailOnlyOnce() async throws {
        let cache = createdBroadcastCache("new-event")
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(), broadcastPageResponse(status: "ready", bound: true), matchingStreamPage(),
            .init(data: Data(), statusCode: 200),
            matchingStreamPage(), emptyYouTubePage(), broadcastPageResponse(status: "ready", bound: true),
            matchingStreamPage(), emptyYouTubePage(), broadcastPageResponse(status: "ready", bound: true),
            .init(data: Data(), statusCode: 200),
        ])
        let first = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        let second = Data([0xFF, 0xD8, 0x02, 0xFF, 0xD9])
        for thumbnail in [first, first, second] {
            // Every Start uses a new service; only the shared cache remembers.
            let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: cache)
            _ = try await service.prepareForStreaming(
                streamKey: "test-key", preferences: setupPreferences(), thumbnailData: thumbnail
            )
        }
        let uploads = await transport.requests.filter { $0.url?.path.hasSuffix("/thumbnails/set") == true }
        #expect(uploads.map(\.httpBody) == [first, second])
        #expect(await transport.requestCount == 11)
    }

    @Test @MainActor
    func startAppliesTheSavedEmbeddingChoiceToAnExistingBroadcast() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(), broadcastPageResponse(status: "ready", bound: true), matchingStreamPage(),
            broadcastResourceResponse(status: "ready", bound: true),
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: createdBroadcastCache("new-event"))
        var preferences = setupPreferences()
        preferences.enableEmbed = true
        let preparation = try await service.prepareForStreaming(streamKey: "test-key", preferences: preferences)
        #expect(preparation.broadcast.enableEmbed)
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "GET", "PUT"])
        let body = try #require(JSONSerialization.jsonObject(with: requests[3].httpBody!) as? [String: Any])
        let details = try #require(body["contentDetails"] as? [String: Any])
        #expect(details["enableEmbed"] as? Bool == true)
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
            tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache()
        )

        await #expect(throws: YouTubeError.invalidResponse) {
            _ = try await service.listPlaylists()
        }
        #expect(await transport.requestCount == 2)
    }

    @Test(arguments: [500, 503]) @MainActor
    func statusDiscoveryFailureWarnsAndTheNextRefreshCanRecover(_ statusCode: Int) async throws {
        let captured = CapturedYouTubeDiagnostics()
        let transport = MockYouTubeAPITransport(responses: [
            .init(data: Data(#"{"error":{"message":"Service unavailable"}}"#.utf8), statusCode: statusCode),
            currentBroadcastPage(status: "live"), matchingStreamPage(),
        ])
        let service = YouTubeService(
            transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache(),
            diagnostics: captured.diagnostics.forStatusMonitoring()
        )
        await #expect(throws: YouTubeError.apiError(statusCode, "Service unavailable")) {
            _ = try await service.findBroadcastForStreamKey("test-key")
        }
        let warnings = captured.entries.filter { $0.1 == .warning }.map(\.0)
        #expect(warnings.count == 2)
        #expect(warnings.contains { $0.contains("liveBroadcasts.list: HTTP \(statusCode)") })
        #expect(warnings.contains { $0.contains("page 1 failed after 0 items; page token present=false") })
        #expect(!captured.entries.contains { $0.1 == .error })
        #expect(!service.isLoading)
        #expect(await transport.requestCount == 1) // Leave retries to the polling interval.

        let recovered = try await service.findBroadcastForStreamKey("test-key")
        #expect(recovered.lifeCycleStatus == "live")
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests[0].url == requests[1].url)
        let query = queryItems(in: requests[0])
        #expect(query.filter { ["broadcastStatus", "id", "mine"].contains($0.name) }
            == [URLQueryItem(name: "broadcastStatus", value: "active")])
        #expect(!query.contains { $0.name == "pageToken" })
    }

    @Test @MainActor
    func lightweightStatusFailureWarnsAndRecoversWithoutChangingBroadcasts() async throws {
        let captured = CapturedYouTubeDiagnostics()
        let transport = MockYouTubeAPITransport(responses: [
            .init(data: Data(#"{"error":{"message":"Service unavailable"}}"#.utf8), statusCode: 503),
            currentBroadcastPage(status: "live"),
        ])
        let service = YouTubeService(
            transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache(),
            diagnostics: captured.diagnostics.forStatusMonitoring()
        )
        await #expect(throws: YouTubeError.apiError(503, "Service unavailable")) {
            _ = try await service.fetchBroadcastStatus(broadcastId: "ready")
        }
        #expect(captured.entries.last?.1 == .warning)
        #expect(!captured.entries.contains { $0.1 == .error })
        #expect(try await service.fetchBroadcastStatus(broadcastId: "ready") == "live")
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].url == requests[1].url)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test @MainActor
    func unavailableYouTubeStillReportsAnErrorWhenItPreventsStreamPreparation() async throws {
        let captured = CapturedYouTubeDiagnostics()
        let transport = MockYouTubeAPITransport(responses: [
            .init(data: Data(#"{"error":{"message":"Service unavailable"}}"#.utf8), statusCode: 503),
        ])
        let service = YouTubeService(
            transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache(),
            diagnostics: captured.diagnostics
        )
        await #expect(throws: YouTubeError.apiError(503, "Service unavailable")) {
            _ = try await service.prepareForStreaming(streamKey: "test-key")
        }
        #expect(captured.entries.filter { $0.1 == .error }.count == 2)
        #expect(await transport.requestCount == 1)
        #expect(!service.isLoading)
    }

    @Test(arguments: [YouTubeAPIOperation.thumbnail, .playlistItems, .insertPlaylistItem])
    func optionalOperationsLogWarningsForHTTPNetworkAndDecodingFailures(_ operation: YouTubeAPIOperation) async throws {
        let captured = CapturedYouTubeDiagnostics()
        let request = URLRequest(url: URL(string: "https://example.invalid/optional")!)
        let http = YouTubeAPIRequestExecutor(transport: MockYouTubeAPITransport(responses: [
            .init(data: Data(#"{"error":{"message":"Unavailable"}}"#.utf8), statusCode: 503)
        ]), diagnostics: captured.diagnostics)
        await #expect(throws: YouTubeError.self) { _ = try await http.data(for: request, operation: operation) }
        let network = YouTubeAPIRequestExecutor(transport: FailingYouTubeAPITransport(), diagnostics: captured.diagnostics)
        await #expect(throws: URLError.self) { _ = try await network.data(for: request, operation: operation) }
        #expect(throws: YouTubeError.self) {
            _ = try http.decode(YouTubeIdentifierResource.self, from: Data("invalid".utf8), operation: operation)
        }
        #expect(captured.entries.filter { $0.1 == .warning }.count == 3)
        #expect(!captured.entries.contains { $0.1 == .error })
    }

    @Test func requestDiagnosticsReportGoogleReasonsWithoutCredentials() async throws {
        let captured = CapturedYouTubeDiagnostics()
        let secret = "access-canary-123"
        let response = YouTubeAPIResponse(
            data: Data(#"{"error":{"message":"Bearer access-canary-123 at https://example.invalid/?cid=key-canary","status":"INTERNAL","errors":[{"domain":"global","reason":"backendError"}]}}"#.utf8),
            statusCode: 500, requestID: "google-request-123"
        )
        let transport = MockYouTubeAPITransport(responses: [response])
        let executor = YouTubeAPIRequestExecutor(transport: transport, diagnostics: captured.diagnostics)
        var request = URLRequest(url: URL(string: "https://example.invalid/liveStreams?pageToken=page-canary")!)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        do {
            _ = try await executor.data(for: request, operation: .streams)
            Issue.record("Expected HTTP 500")
        } catch let error as YouTubeError {
            #expect(!error.localizedDescription.contains(secret))
            #expect(!error.localizedDescription.contains("key-canary"))
        }
        let log = captured.text
        #expect(log.contains("liveStreams.list: HTTP 500"))
        #expect(log.contains("Google request ID=google-request-123"))
        #expect(log.contains("status=INTERNAL; domain=global; reason=backendError"))
        #expect(!log.contains(secret))
        #expect(!log.contains("key-canary"))
        #expect(!log.contains("page-canary"))
        #expect(!log.contains("https://"))
        #expect(captured.entries.last?.1 == .error)
        #expect(await transport.requestCount == 1)
    }

    @Test(arguments: [YouTubeAPIOperation.exchangeCode, .refreshToken])
    func oauthDiagnosticsIdentifyTokenStageAndRedactFormValues(_ operation: YouTubeAPIOperation) async throws {
        let captured = CapturedYouTubeDiagnostics()
        let secret = "credential+canary/123="
        let data = try JSONSerialization.data(withJSONObject: [
            "error": "invalid_grant", "error_description": "Rejected \(secret)",
        ])
        let executor = YouTubeAPIRequestExecutor(
            transport: MockYouTubeAPITransport(responses: [.init(data: data, statusCode: 400)]),
            diagnostics: captured.diagnostics
        )
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoder.encode(["code": secret, "refresh_token": secret, "code_verifier": secret])
        do {
            _ = try await executor.data(for: request, operation: operation)
            Issue.record("Expected OAuth failure")
        } catch let error as YouTubeError {
            #expect(!error.localizedDescription.contains(secret))
        }
        #expect(captured.text.contains("\(operation.rawValue): HTTP 400"))
        #expect(captured.text.contains("OAuth reason=invalid_grant"))
        #expect(!captured.text.contains(secret))
    }

    @Test func diagnosticTextRedactsBeforeTruncationAndRemovesNewlines() {
        let secret = "sensitive-credential-canary"
        let result = YouTubeDiagnostics.text(String(repeating: "a", count: 990) + secret, secrets: [secret])
        #expect(!result.contains("sensitive-"))
        #expect(YouTubeDiagnostics.text("backendError\nforged entry\rnext") == "backendError forged entry next")
    }

    @Test func transportFailureDiagnosticsOmitUnderlyingURLAndErrorDescription() async throws {
        let captured = CapturedYouTubeDiagnostics()
        let executor = YouTubeAPIRequestExecutor(transport: FailingYouTubeAPITransport(), diagnostics: captured.diagnostics)
        do {
            _ = try await executor.data(for: URLRequest(url: URL(string: "https://example.invalid")!), operation: .channels)
            Issue.record("Expected timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
        #expect(captured.text.contains("channels.list: NSURLErrorDomain code=-1001"))
        #expect(!captured.text.contains("transport-canary"))
        #expect(captured.entries.last?.1 == .warning)
    }

    @Test @MainActor
    func channelNameLoadsWithoutAStreamKeyAndFollowsTheAuthorizedAccount() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            settingsDiagnosticResponses()[0],
            .init(data: Data(#"{"items":[{"id":"UC-other","snippet":{"title":"Other brand channel"}}]}"#.utf8), statusCode: 200),
        ])
        let store = validMemoryTokenStore()
        let service = YouTubeService(transport: transport, tokenStore: store, discoveryCache: YouTubeDiscoveryCache())
        try await service.loadAuthorizedChannel()
        #expect(service.authorizedChannelName == "Brand channel")
        #expect(!service.isLoading)

        store.refreshToken = "other-account"
        store.accessToken = "other-access"
        try await service.loadAuthorizedChannel()
        #expect(service.authorizedChannelName == "Other brand channel")
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.path == "/youtube/v3/channels" })
        #expect(requests.allSatisfy { queryItems(in: $0).contains(URLQueryItem(name: "mine", value: "true")) })
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer other-access")
        #expect(service.signOut())
        #expect(service.authorizedChannelName == nil)
    }

    @Test(arguments: [
        #"{"items":[]}"#,
        #"{"items":[{"id":"UC-test-channel"}]}"#,
        #"{"items":[{"id":"UC-test-channel","snippet":{"title":"  "}}]}"#,
        #"{"items":[{"id":"UC-one","snippet":{"title":"First"}},{"id":"UC-two","snippet":{"title":"Second"}}]}"#,
        #"{"items":[{"id":"UC-test-channel","snippet":{"title":"Brand channel"}}],"nextPageToken":"more"}"#,
    ]) @MainActor
    func channelNameDoesNotGuessWhenYouTubeCannotIdentifyOneChannel(body: String) async throws {
        let transport = MockYouTubeAPITransport(responses: [.init(data: Data(body.utf8), statusCode: 200)])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
        try await service.loadAuthorizedChannel()
        #expect(service.authorizedChannelName == nil)
        #expect(service.isSignedIn)
        #expect(service.errorMessage == nil)
    }

    @Test @MainActor
    func failedChannelRefreshDoesNotDisplayAnUnverifiedPreviousName() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            settingsDiagnosticResponses()[0],
            .init(data: Data(#"{"error":{"message":"Unavailable"}}"#.utf8), statusCode: 503),
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
        try await service.loadAuthorizedChannel()
        #expect(service.authorizedChannelName == "Brand channel")
        try await service.loadAuthorizedChannel()
        #expect(service.authorizedChannelName == nil)
        #expect(service.isSignedIn)
        #expect(service.errorMessage == nil)
        #expect(!service.isLoading)
    }

    @Test @MainActor
    func refreshKeepsTheNameForTheSameAccountButHidesItForAnotherAccount() async throws {
        let transport = DeferredYouTubeChannelTransport()
        let store = validMemoryTokenStore()
        let service = YouTubeService(transport: transport, tokenStore: store, discoveryCache: YouTubeDiscoveryCache())
        let first = Task { try await service.loadAuthorizedChannel() }
        await transport.waitUntilStarted()
        await transport.complete(with: settingsDiagnosticResponses()[0])
        try await first.value
        #expect(service.authorizedChannelName == "Brand channel")

        // Refreshing the same authorization must not flicker to "Loading…".
        let refresh = Task { try await service.loadAuthorizedChannel() }
        await transport.waitUntilStarted()
        #expect(service.authorizedChannelName == "Brand channel")
        await transport.complete(with: settingsDiagnosticResponses()[0])
        try await refresh.value
        #expect(service.authorizedChannelName == "Brand channel")

        store.refreshToken = "other-account"
        let other = Task { try await service.loadAuthorizedChannel() }
        await transport.waitUntilStarted()
        #expect(service.authorizedChannelName == nil)
        await transport.complete(with: .init(
            data: Data(#"{"items":[{"id":"UC-other","snippet":{"title":"Other brand channel"}}]}"#.utf8), statusCode: 200
        ))
        try await other.value
        #expect(service.authorizedChannelName == "Other brand channel")
    }

    @Test @MainActor
    func accountChangeDuringASameAccountRefreshHidesThePreviousName() async throws {
        let transport = DeferredYouTubeChannelTransport()
        let store = validMemoryTokenStore()
        let service = YouTubeService(transport: transport, tokenStore: store, discoveryCache: YouTubeDiscoveryCache())
        let first = Task { try await service.loadAuthorizedChannel() }
        await transport.waitUntilStarted()
        await transport.complete(with: settingsDiagnosticResponses()[0])
        try await first.value
        let refresh = Task { try await service.loadAuthorizedChannel() }
        await transport.waitUntilStarted()
        store.refreshToken = "other-account"
        await transport.complete(with: settingsDiagnosticResponses()[0])
        await #expect(throws: YouTubeError.notSignedIn) { try await refresh.value }
        #expect(service.authorizedChannelName == nil)
    }

    @Test(arguments: [false, true]) @MainActor
    func lateChannelResponseCannotRestoreThePreviousAccount(signOut: Bool) async throws {
        let transport = DeferredYouTubeChannelTransport()
        let store = validMemoryTokenStore()
        let service = YouTubeService(transport: transport, tokenStore: store, discoveryCache: YouTubeDiscoveryCache())
        let lookup = Task { try await service.loadAuthorizedChannel() }
        await transport.waitUntilStarted()
        if signOut {
            #expect(service.signOut())
        } else {
            store.refreshToken = "other-account"
        }
        await transport.complete(with: settingsDiagnosticResponses()[0])
        await #expect(throws: YouTubeError.notSignedIn) { try await lookup.value }
        #expect(service.authorizedChannelName == nil)
        #expect(!service.isLoading)
    }

    @Test @MainActor
    func settingsDiagnosticsIdentifyAuthorizedChannelAndSuccessfulDiscovery() async throws {
        let captured = CapturedYouTubeDiagnostics()
        let transport = MockYouTubeAPITransport(responses: settingsDiagnosticResponses())
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: createdBroadcastCache("ready"), diagnostics: captured.diagnostics)
        let settings = try await service.loadSettingsConfiguration(forStreamKey: "test-key")
        #expect(settings.broadcast.id == "ready")
        #expect(settings.playlists.isEmpty)
        #expect(service.authorizedChannelName == "Brand channel")
        let infoEntries = captured.entries.filter { $0.1 == .info }
        #expect(infoEntries.map(\.0) == ["YouTube Settings: configuration loaded; broadcast=Ready; 0 playlists"])
        #expect(captured.entries.filter { $0.1 != .info }.allSatisfy { $0.1 == .debug })
        #expect(captured.text.contains("authorized channel: Brand channel [UC-test-channel]"))
        #expect(captured.text.contains("1 streams; 1 match the configured key"))
        #expect(captured.text.contains("1 broadcasts; 1 bound to the matching stream"))
        #expect(!captured.text.contains("test-key"))
        #expect(!captured.text.contains("valid-access"))
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "GET", "GET", "GET"])
        #expect(requests.first?.timeoutInterval == 5)
        #expect(!service.isLoading)
    }

    @Test(arguments: [1, 2, 3, 4]) @MainActor
    func settingsDiagnosticsNameEachFailingDiscoveryStage(_ stage: Int) async throws {
        let captured = CapturedYouTubeDiagnostics()
        let operations: [YouTubeAPIOperation] = [.channels, .broadcasts, .broadcasts, .streams, .playlists]
        var responses = Array(settingsDiagnosticResponses().prefix(stage + 1))
        responses[stage] = .init(data: Data(#"{"error":{"message":"Internal error encountered.","errors":[{"reason":"backendError"}]}}"#.utf8), statusCode: 500)
        let transport = MockYouTubeAPITransport(responses: responses)
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: createdBroadcastCache("ready"), diagnostics: captured.diagnostics)
        await #expect(throws: YouTubeError.apiError(500, "Internal error encountered.")) {
            _ = try await service.loadSettingsConfiguration(forStreamKey: "test-key")
        }
        #expect(captured.text.contains("\(operations[stage].rawValue): HTTP 500"))
        #expect(captured.text.contains("reason=backendError"))
        #expect(captured.entries.contains { $0.1 == .error })
        #expect(!captured.entries.contains { $0.1 == .info })
        #expect(captured.text.contains("authorized channel: Brand channel"))
        #expect(service.authorizedChannelName == "Brand channel")
        #expect(await transport.requestCount == stage + 1)
        #expect(!service.isLoading)
    }

    @Test(arguments: [401, 500]) @MainActor
    func optionalChannelFailureDoesNotBlockSettingsOrRefreshAuthorization(_ status: Int) async throws {
        let captured = CapturedYouTubeDiagnostics()
        var responses = settingsDiagnosticResponses()
        responses[0] = .init(data: Data(#"{"error":{"message":"Channel check failed"}}"#.utf8), statusCode: status)
        let transport = MockYouTubeAPITransport(responses: responses)
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: createdBroadcastCache("ready"), diagnostics: captured.diagnostics)
        let settings = try await service.loadSettingsConfiguration(forStreamKey: "test-key")
        #expect(settings.broadcast.id == "ready")
        #expect(captured.text.contains("authorized channel check unavailable (HTTP \(status)); continuing"))
        #expect(!captured.entries.contains { $0.1 == .error })
        #expect(await transport.requestCount == 5)
        #expect(service.errorMessage == nil)
    }

    @Test @MainActor
    func initialTokenFailureIsReportedOnceBeforeChannelOrStreamDiscovery() async throws {
        let captured = CapturedYouTubeDiagnostics()
        let transport = MockYouTubeAPITransport(responses: [
            .init(data: Data(#"{"error":{"message":"Internal error encountered."}}"#.utf8), statusCode: 500),
        ])
        let store = MemoryYouTubeTokenStore(accessToken: nil, refreshToken: "refresh-canary", expiry: nil)
        let service = YouTubeService(transport: transport, tokenStore: store, discoveryCache: YouTubeDiscoveryCache(), diagnostics: captured.diagnostics)
        await #expect(throws: YouTubeError.apiError(500, "Internal error encountered.")) {
            _ = try await service.loadSettingsConfiguration(forStreamKey: "test-key")
        }
        #expect(captured.text.contains("oauth.refreshToken: HTTP 500"))
        #expect(!captured.text.contains("channels.list"))
        #expect(!captured.text.contains("refresh-canary"))
        #expect(await transport.requestCount == 1)
        #expect(!service.isLoading)
    }

    @Test @MainActor
    func cancellingChannelDiagnosticDoesNotContinueToStreamDiscovery() async throws {
        let transport = SuspendingYouTubeAPITransport()
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
        let task = Task { try await service.loadSettingsConfiguration(forStreamKey: "test-key") }
        await transport.waitUntilStarted()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!service.isLoading)
    }

    @Test @MainActor
    func cancellationPropagatesAndClearsLoadingState() async throws {
        let transport = SuspendingYouTubeAPITransport()
        let service = YouTubeService(
            transport: transport,
            tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache()
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

private final class CapturedYouTubeDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(String, LogLevel)] = []
    var diagnostics: YouTubeDiagnostics {
        YouTubeDiagnostics(log: { [self] message, level in lock.withLock { storage.append((message, level)) } })
    }
    var entries: [(String, LogLevel)] { lock.withLock { storage } }
    var text: String { entries.map(\.0).joined(separator: "\n") }
}

private struct FailingYouTubeAPITransport: YouTubeAPITransport {
    func response(for request: URLRequest) async throws -> YouTubeAPIResponse {
        throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "https://example.invalid/?cid=transport-canary"])
    }
}

/// A cache that remembers `id` as the broadcast Tubeist created for "test-key",
/// the only upcoming broadcast "New stream" may reuse.
@MainActor private func createdBroadcastCache(_ id: String) -> YouTubeDiscoveryCache {
    let cache = YouTubeDiscoveryCache()
    cache.setID(id, kind: "createdBroadcast", for: YouTubeDiscoveryCache.key(
        scope: YouTubeDiscoveryCache.scope(refreshToken: "refresh-token"), streamKey: "test-key"))
    return cache
}

private func streamResourceResponse() -> YouTubeAPIResponse {
    let object = try! JSONSerialization.jsonObject(with: matchingStreamPage().data) as! [String: Any]
    let resource = (object["items"] as! [[String: Any]])[0]
    return .init(data: try! JSONSerialization.data(withJSONObject: resource), statusCode: 200)
}

private func broadcastResourceResponse(status: String, bound: Bool, autoStop: Bool? = nil) -> YouTubeAPIResponse {
    let statusFields: [String: Any] = ["privacyStatus": "private", "lifeCycleStatus": status, "selfDeclaredMadeForKids": false]
    var details: [String: Any] = ["enableEmbed": false]
    if let autoStop { details["enableAutoStop"] = autoStop }
    if bound { details["boundStreamId"] = "stream-1" }
    let object: [String: Any] = [
        "id": "new-event", "snippet": ["title": "Saved title"],
        "status": statusFields,
        "contentDetails": details
    ]
    return .init(data: try! JSONSerialization.data(withJSONObject: object), statusCode: 200)
}

private func broadcastPageResponse(status: String, bound: Bool, autoStop: Bool? = nil) -> YouTubeAPIResponse {
    let resource = try! JSONSerialization.jsonObject(with: broadcastResourceResponse(status: status, bound: bound, autoStop: autoStop).data)
    return .init(data: try! JSONSerialization.data(withJSONObject: ["items": [resource]]), statusCode: 200)
}

private func setupPreferences() -> YouTubeBroadcastPreferences {
    YouTubeBroadcastPreferences(
        streamId: "stream-1", title: "Saved title", privacyStatus: "private", enableDvr: true,
        latencyPreference: "normal", enableMonitorStream: false, broadcastStreamDelayMs: 0,
        enableEmbed: false, recordFromStart: true, enableAutoStart: true, enableAutoStop: true,
        playlistId: nil, selfDeclaredMadeForKids: false
    )
}

private func emptyYouTubePage() -> YouTubeAPIResponse {
    .init(data: Data(#"{"items":[]}"#.utf8), statusCode: 200)
}

private func currentBroadcastPage(status: String = "ready", nextPageToken: String? = nil) -> YouTubeAPIResponse {
    var page: [String: Any] = ["items": [[
        "id": "ready", "snippet": ["title": "Next"],
        "status": ["privacyStatus": "unlisted", "lifeCycleStatus": status],
        "contentDetails": ["boundStreamId": "stream-1"],
    ]]]
    page["nextPageToken"] = nextPageToken
    return .init(data: try! JSONSerialization.data(withJSONObject: page), statusCode: 200)
}

private func studioPlannedPage(
    status: String, id: String = "planned-1", title: String = "Planned match", stream: String = "stream-1"
) -> YouTubeAPIResponse {
    let page: [String: Any] = ["items": [[
        "id": id, "snippet": ["title": title],
        "status": ["privacyStatus": "unlisted", "lifeCycleStatus": status],
        "contentDetails": ["boundStreamId": stream],
    ]]]
    return .init(data: try! JSONSerialization.data(withJSONObject: page), statusCode: 200)
}

private func matchingStreamPage() -> YouTubeAPIResponse {
    .init(data: Data(#"{"items":[{"id":"stream-1","cdn":{"ingestionType":"hls","ingestionInfo":{"streamName":"test-key","ingestionAddress":"https://a.upload.youtube.com/http_upload_hls?cid=test-key&file="}}}]}"#.utf8), statusCode: 200)
}

private func queryItems(in request: URLRequest) -> [URLQueryItem] {
    request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
}

private func settingsDiagnosticResponses() -> [YouTubeAPIResponse] {
    [
        .init(data: Data(#"{"items":[{"id":"UC-test-channel","snippet":{"title":"Brand channel"}}]}"#.utf8), statusCode: 200),
        emptyYouTubePage(), currentBroadcastPage(), matchingStreamPage(), emptyYouTubePage(),
    ]
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

private actor DeferredYouTubeChannelTransport: YouTubeAPITransport {
    private var continuation: CheckedContinuation<YouTubeAPIResponse, Never>?

    func response(for request: URLRequest) async throws -> YouTubeAPIResponse {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }

    func complete(with response: YouTubeAPIResponse) {
        continuation?.resume(returning: response)
        continuation = nil
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

// MARK: - Start on a planned or restart selection

extension YouTubeServiceTests {
    @Test @MainActor
    func plannedStartSendsOnlyChangedFieldsAndForcesGoLive() async throws {
        let fixture = PlannedStartFixture(m5: plannedM5(stream: "match-1", enableAutoStart: false))
        var selection = fixture.selection
        selection.edited.title = "Match 5 – Final"

        let preparation = try await fixture.start(selection)

        #expect(preparation.broadcast.id == "m5")
        #expect(preparation.broadcast.title == "Match 5 – Final")
        #expect(preparation.warnings.isEmpty)
        let requests = await fixture.transport.requests
        let lookup = try #require(requests.first { queryItems(in: $0).contains(.init(name: "id", value: "m5")) })
        #expect(lookup.httpMethod == "GET")
        #expect(queryItems(in: lookup).contains(.init(name: "part", value: "snippet,status,contentDetails")))
        let puts = requests.filter { $0.httpMethod == "PUT" }
        #expect(puts.count == 1)
        let body = try plannedJSONBody(puts.first?.httpBody)
        #expect(body["id"] as? String == "m5")
        #expect((body["snippet"] as? [String: Any])?["title"] as? String == "Match 5 – Final")
        #expect((body["snippet"] as? [String: Any])?["scheduledStartTime"] as? String == fixture.today)
        #expect((body["status"] as? [String: Any])?["privacyStatus"] as? String == "unlisted")
        let details = try #require(body["contentDetails"] as? [String: Any])
        #expect(details["enableAutoStart"] as? Bool == true)
        #expect(details["enableAutoStop"] as? Bool == true)
        let monitor = try #require(details["monitorStream"] as? [String: Any])
        #expect(monitor["enableMonitorStream"] as? Bool == false)
        #expect(monitor["broadcastStreamDelayMs"] as? Int == 0)
        #expect(!requests.contains { $0.httpMethod == "POST" })
        #expect(!requests.contains { $0.url?.path.contains("thumbnails") == true })
        #expect(!requests.contains { $0.url?.path.hasSuffix("/playlistItems") == true })
    }

    @Test @MainActor
    func plannedStartWithNoChangesAndGoLiveAlreadySetSendsNoWrite() async throws {
        let fixture = PlannedStartFixture()

        let preparation = try await fixture.start(fixture.selection)

        #expect(preparation.broadcast.id == "m5")
        #expect(preparation.healthTarget.broadcastID == "m5")
        #expect(preparation.completionTarget?.id == "m5")
        let methods = await fixture.transport.requests.map(\.httpMethod)
        #expect(!methods.contains("PUT"))
        #expect(!methods.contains("POST"))
        #expect(!methods.contains("DELETE"))
    }

    enum PlannedRefusal: String, CaseIterable, Sendable {
        case missing, complete, scheduledYesterday
    }

    @Test(arguments: PlannedRefusal.allCases) @MainActor
    func plannedStartIsRefusedWithoutAnyWrite(_ refusal: PlannedRefusal) async throws {
        let yesterday = plannedFixtureNow.addingTimeInterval(-86_400)
        let fixture = PlannedStartFixture(m5: {
            switch refusal {
            case .missing: return nil
            case .complete: return plannedM5(status: "complete")
            default: return plannedM5()
            }
        }())
        let selection = PlannedStreamSelection(
            kind: .planned, broadcastId: "m5",
            streamId: "stream-1",
            scheduledStartTime: refusal == .scheduledYesterday
                ? ISO8601DateFormatter().string(from: yesterday) : fixture.today,
            loaded: fixture.selection.loaded, edited: fixture.selection.edited,
            loadedMembership: nil, thumbnailChanged: true
        )

        await #expect(throws: YouTubeError.plannedBroadcastUnavailable("Match 5")) {
            _ = try await fixture.start(selection, thumbnail: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        }
        let methods = await fixture.transport.requests.map(\.httpMethod)
        #expect(!methods.contains { ["PUT", "POST", "DELETE"].contains($0) })
    }

    @Test func plannedUnavailableErrorNamesTheStream() {
        #expect(YouTubeError.plannedBroadcastUnavailable("Match 5").errorDescription
            == "The planned stream 'Match 5' is no longer available. Choose another in Settings.")
    }

    @Test @MainActor
    func changingPlaylistRemovesTheOldItemThenAdds() async throws {
        let fixture = PlannedStartFixture()
        var selection = fixture.selection
        selection.loaded.playlistId = "old-list"
        selection.edited.playlistId = "new-list"
        selection.loadedMembership = YouTubePlaylistMembership(playlistId: "old-list", itemId: "item-1")

        let preparation = try await fixture.start(selection)

        #expect(preparation.warnings.isEmpty)
        let requests = await fixture.transport.requests
        let delete = try #require(requests.firstIndex { $0.httpMethod == "DELETE" })
        #expect(queryItems(in: requests[delete]) == [URLQueryItem(name: "id", value: "item-1")])
        let insert = try #require(requests.firstIndex {
            $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/playlistItems") == true
        })
        #expect(delete < insert)
        #expect(requests[insert].httpBody?.range(of: Data(#""playlistId":"new-list""#.utf8)) != nil)
    }

    @Test @MainActor
    func failedRemovalWarnsButStillStarts() async throws {
        let fixture = PlannedStartFixture(deleteStatus: 500)
        var selection = fixture.selection
        selection.loaded.playlistId = "old-list"
        selection.edited.playlistId = nil
        selection.loadedMembership = YouTubePlaylistMembership(playlistId: "old-list", itemId: "item-1")

        let preparation = try await fixture.start(selection)

        #expect(preparation.broadcast.id == "m5")
        #expect(preparation.warnings == [
            "Could not remove 'Match 5' from its previous playlist. Check it in YouTube Studio."
        ])
        #expect(!(await fixture.transport.requests).contains { $0.httpMethod == "POST" })
    }

    @Test @MainActor
    func unchangedThumbnailIsNotUploaded() async throws {
        let fixture = PlannedStartFixture()
        var selection = fixture.selection
        selection.thumbnailChanged = false

        _ = try await fixture.start(selection, thumbnail: Data([0xFF, 0xD8, 0xFF, 0xD9]))

        #expect(!(await fixture.transport.requests).contains { $0.url?.path.hasSuffix("/thumbnails/set") == true })
    }

    @Test @MainActor
    func changedThumbnailIsUploaded() async throws {
        let fixture = PlannedStartFixture()
        var selection = fixture.selection
        selection.thumbnailChanged = true
        let image = Data([0xFF, 0xD8, 0xFF, 0xD9])

        _ = try await fixture.start(selection, thumbnail: image)

        let upload = try #require(await fixture.transport.requests.first { $0.url?.path.hasSuffix("/thumbnails/set") == true })
        #expect(queryItems(in: upload).contains(.init(name: "videoId", value: "m5")))
        #expect(upload.httpBody == image)
    }

    @Test @MainActor
    func restartCreatesANewBroadcastWithTheEditedDetails() async throws {
        // The original broadcast has ended, so Restart needs a new one.
        let fixture = PlannedStartFixture(m5: plannedM5(status: "complete"))
        var selection = fixture.selection
        selection.edited.title = "Match 5 – Part 2"
        selection.edited.privacyStatus = "public"
        selection.edited.playlistId = "season"
        selection = selection.restarting()
        let image = Data([0xFF, 0xD8, 0xFF, 0xD9])

        let preparation = try await fixture.start(selection, thumbnail: image)

        #expect(preparation.broadcast.id == "new-event")
        let requests = await fixture.transport.requests
        let insert = try #require(requests.firstIndex {
            $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/liveBroadcasts") == true
        })
        let body = try plannedJSONBody(requests[insert].httpBody)
        #expect((body["snippet"] as? [String: Any])?["title"] as? String == "Match 5 – Part 2")
        #expect((body["status"] as? [String: Any])?["privacyStatus"] as? String == "public")
        let bind = try #require(requests.firstIndex { $0.url?.path.hasSuffix("/liveBroadcasts/bind") == true })
        #expect(insert < bind)
        // The ended original is only looked up, never written.
        #expect(try requests.filter { $0.httpMethod == "PUT" }.allSatisfy {
            try plannedJSONBody($0.httpBody)["id"] as? String != "m5"
        })
        let playlistInsert = try #require(requests.first {
            $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/playlistItems") == true
        })
        #expect(playlistInsert.httpBody?.range(of: Data(#""playlistId":"season""#.utf8)) != nil)
        #expect(playlistInsert.httpBody?.range(of: Data(#""videoId":"new-event""#.utf8)) != nil)
        let upload = try #require(requests.first { $0.url?.path.hasSuffix("/thumbnails/set") == true })
        #expect(queryItems(in: upload).contains(.init(name: "videoId", value: "new-event")))
        #expect(!requests.contains { $0.httpMethod == "DELETE" })
    }

    @Test @MainActor
    func restartReappliesEditedDetailsToAResumedTubeistBroadcast() async throws {
        // createOrResume returns the cached ready Tubeist broadcast ("Saved title")
        // and ignores the template, so the edited details must be PUT afterwards.
        let cache = YouTubeDiscoveryCache()
        cache.setID("new-event", kind: "createdBroadcast", for: YouTubeDiscoveryCache.key(
            scope: YouTubeDiscoveryCache.scope(refreshToken: "refresh-token"), streamKey: "match-key-1"))
        let fixture = PlannedStartFixture(m5: plannedM5(status: "complete", stream: "match-1"), cache: cache,
                                          upcoming: newEventPage(boundTo: "match-1"), pendingKey: "match-1")
        var selection = fixture.selection
        selection.edited.title = "Match 5 – Final"
        selection = selection.restarting()

        let preparation = try await fixture.start(selection)

        #expect(preparation.broadcast.id == "new-event")
        #expect(preparation.broadcast.title == "Match 5 – Final")
        let requests = await fixture.transport.requests
        #expect(!requests.contains { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/liveBroadcasts") == true })
        let put = try #require(requests.first { $0.httpMethod == "PUT" })
        let body = try plannedJSONBody(put.httpBody)
        #expect(body["id"] as? String == "new-event")
        #expect((body["snippet"] as? [String: Any])?["title"] as? String == "Match 5 – Final")
        #expect((body["status"] as? [String: Any])?["privacyStatus"] as? String == "unlisted")
        let details = try #require(body["contentDetails"] as? [String: Any])
        #expect(details["enableEmbed"] as? Bool == true)
        #expect(details["enableAutoStart"] as? Bool == true)
        #expect(details["enableAutoStop"] as? Bool == true)
        let monitor = try #require(details["monitorStream"] as? [String: Any])
        #expect(monitor["enableMonitorStream"] as? Bool == false)
        #expect(monitor["broadcastStreamDelayMs"] as? Int == 0)
    }

    @Test @MainActor
    func plannedStartKeepsAStudioChangeToAnUneditedField() async throws {
        // Picked as unlisted; Studio made it public afterwards. Only the title was edited.
        let fixture = PlannedStartFixture(m5: plannedM5(stream: "match-1", privacy: "public"))
        var selection = fixture.selection
        selection.edited.title = "Match 5 – Final"

        let preparation = try await fixture.start(selection)

        let put = try #require(await fixture.transport.requests.first { $0.httpMethod == "PUT" })
        let body = try plannedJSONBody(put.httpBody)
        #expect((body["snippet"] as? [String: Any])?["title"] as? String == "Match 5 – Final")
        #expect((body["status"] as? [String: Any])?["privacyStatus"] as? String == "public")
        #expect(preparation.broadcast.privacyStatus == "public")
        // Restart carries what was applied at Start, not the pick-time value.
        let restart = selection.restarting(after: preparation.broadcast)
        #expect(restart.edited.privacyStatus == "public")
        #expect(restart.loaded.privacyStatus == "public")
        #expect(restart.edited.title == "Match 5 – Final")
    }

    @Test @MainActor
    func restartReusesTheOriginalWhileItIsStillReady() async throws {
        // Start then a quick Stop leaves the planned broadcast ready (auto-start
        // waits for ingest). Restart must use it rather than insert a duplicate.
        let fixture = PlannedStartFixture(m5: plannedM5(stream: "match-1", enableAutoStart: false))
        let selection = fixture.selection.restarting()

        let preparation = try await fixture.start(selection, thumbnail: Data([0xFF, 0xD8, 0xFF, 0xD9]))

        #expect(preparation.broadcast.id == "m5")
        #expect(preparation.healthTarget.broadcastID == "m5")
        let requests = await fixture.transport.requests
        let lookup = try #require(requests.first { queryItems(in: $0).contains(.init(name: "id", value: "m5")) })
        #expect(lookup.httpMethod == "GET")
        #expect(!requests.contains { $0.httpMethod == "POST" })
        #expect(!requests.contains { $0.httpMethod == "DELETE" })
        let puts = requests.filter { $0.httpMethod == "PUT" }
        #expect(puts.count == 1)
        let body = try plannedJSONBody(puts.first?.httpBody)
        #expect(body["id"] as? String == "m5")
        #expect((body["status"] as? [String: Any])?["privacyStatus"] as? String == "unlisted")
        #expect((body["contentDetails"] as? [String: Any])?["enableAutoStart"] as? Bool == true)
    }

    @Test @MainActor
    func restartOnAStillReadyOriginalWithNothingToChangeSendsNoWrite() async throws {
        let fixture = PlannedStartFixture()

        let preparation = try await fixture.start(fixture.selection.restarting())

        #expect(preparation.broadcast.id == "m5")
        let methods = await fixture.transport.requests.map(\.httpMethod)
        #expect(!methods.contains { ["PUT", "POST", "DELETE"].contains($0) })
    }

    @Test @MainActor
    func restartOnAStillReadyOriginalAddsAChangedPlaylistAndWarnsAboutTheOldOne() async throws {
        let fixture = PlannedStartFixture()
        var selection = fixture.selection
        selection.loaded.playlistId = "old-list"
        selection.edited.playlistId = "old-list"
        selection = selection.restarting()
        selection.edited.playlistId = "new-list"

        let preparation = try await fixture.start(selection)

        #expect(preparation.broadcast.id == "m5")
        #expect(preparation.warnings == [
            "'Match 5' may still be in its previous playlist. Check it in YouTube Studio."
        ])
        let requests = await fixture.transport.requests
        let inserts = requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/playlistItems") == true }
        #expect(inserts.count == 1)
        #expect(inserts.first?.httpBody?.range(of: Data(#""videoId":"m5""#.utf8)) != nil)
        #expect(!requests.contains { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/liveBroadcasts") == true })
    }

    @Test @MainActor
    func restartCreatesANewBroadcastWhenTheOriginalIsGone() async throws {
        let fixture = PlannedStartFixture(m5: nil)

        let preparation = try await fixture.start(fixture.selection.restarting())

        #expect(preparation.broadcast.id == "new-event")
        #expect(await fixture.transport.requests.contains {
            $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/liveBroadcasts") == true
        })
    }

    @Test @MainActor
    func restartIsRefusedWhenTheReadyOriginalWasMovedToAnotherKey() async throws {
        let fixture = PlannedStartFixture(m5: plannedM5(stream: "stream-2"))

        await #expect(throws: YouTubeError.plannedBroadcastUnavailable("Match 5")) {
            _ = try await fixture.start(fixture.selection.restarting())
        }
        let methods = await fixture.transport.requests.map(\.httpMethod)
        #expect(!methods.contains { ["PUT", "POST", "DELETE"].contains($0) })
    }

    @Test @MainActor
    func restartFromAnEarlierDayIsRefused() async throws {
        let fixture = PlannedStartFixture()
        let earlier = PlannedStreamSelection(
            kind: .restart, broadcastId: "m5", streamId: "stream-1",
            scheduledStartTime: ISO8601DateFormatter().string(from: plannedFixtureNow.addingTimeInterval(-86_400)),
            loaded: fixture.selection.loaded, edited: fixture.selection.edited,
            loadedMembership: nil, thumbnailChanged: false
        )

        await #expect(throws: YouTubeError.plannedBroadcastUnavailable("Match 5")) {
            _ = try await fixture.start(earlier)
        }
        let methods = await fixture.transport.requests.map(\.httpMethod)
        #expect(!methods.contains { ["PUT", "POST", "DELETE"].contains($0) })
    }

    @Test @MainActor
    func plannedStartStillRefusesWhileABroadcastIsActive() async throws {
        let fixture = PlannedStartFixture(active: studioPlannedPage(status: "live", id: "active", stream: "match-1"))

        await #expect(throws: YouTubeError.keyInUse("Match 5")) {
            _ = try await fixture.start(fixture.selection)
        }
        let methods = await fixture.transport.requests.map(\.httpMethod)
        #expect(!methods.contains { ["PUT", "POST", "DELETE"].contains($0) })
    }
}

private func plannedJSONBody(_ body: Data?) throws -> [String: Any] {
    let data = try #require(body)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let plannedFixtureNow = Date(timeIntervalSince1970: 1_800_000_000)

private var plannedFixtureCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

/// The Studio-planned "Match 5" broadcast as `liveBroadcasts.list` returns it.
private func plannedM5(
    status: String = "ready", stream: String = "stream-1", enableAutoStart: Bool = true,
    privacy: String = "unlisted"
) -> [String: Any] {
    [
        "id": "m5",
        "snippet": ["title": "Match 5", "scheduledStartTime": ISO8601DateFormatter().string(from: plannedFixtureNow)],
        "status": ["privacyStatus": privacy, "lifeCycleStatus": status, "selfDeclaredMadeForKids": false],
        "contentDetails": [
            "boundStreamId": stream, "enableDvr": true, "latencyPreference": "normal",
            "monitorStream": ["enableMonitorStream": false, "broadcastStreamDelayMs": 0],
            "enableEmbed": true, "recordFromStart": true,
            "enableAutoStart": enableAutoStart, "enableAutoStop": true,
        ],
    ]
}

/// Routes each request by method and path so tests do not depend on call order.
@MainActor private struct PlannedStartFixture {
    let transport: RoutingYouTubeAPITransport
    let service: YouTubeService
    let today = ISO8601DateFormatter().string(from: plannedFixtureNow)
    let selection: PlannedStreamSelection

    init(
        m5: [String: Any]? = plannedM5(stream: "match-1"), deleteStatus: Int = 204,
        cache: YouTubeDiscoveryCache = YouTubeDiscoveryCache(),
        active: YouTubeAPIResponse = emptyYouTubePage(), upcoming: YouTubeAPIResponse = emptyYouTubePage(),
        matchKeys: [Int] = [1, 2], pendingKey: String = "stream-1"
    ) {
        let m5Page = YouTubeAPIResponse(
            data: try! JSONSerialization.data(withJSONObject: ["items": m5.map { [$0] } ?? []]), statusCode: 200)
        transport = RoutingYouTubeAPITransport { request in
            let path = request.url?.path ?? ""
            let query = queryItems(in: request)
            switch (request.httpMethod ?? "GET", path) {
            case ("GET", let p) where p.hasSuffix("/liveStreams"):
                if let id = query.first(where: { $0.name == "id" })?.value, id.hasPrefix("match-") {
                    return matchKeyPage(Int(id.dropFirst("match-".count))!)
                }
                if query.contains(.init(name: "mine", value: "true")) { return channelStreamsPage(matchKeys) }
                return matchingStreamPage()
            case ("POST", let p) where p.hasSuffix("/liveStreams"):
                return .init(data: try! JSONSerialization.data(
                    withJSONObject: matchKeyItem(matchKeys.max().map { $0 + 1 } ?? 1)), statusCode: 200)
            case ("GET", let p) where p.hasSuffix("/liveBroadcasts"):
                if query.contains(.init(name: "broadcastStatus", value: "active")) { return active }
                if query.contains(.init(name: "broadcastStatus", value: "upcoming")) { return upcoming }
                if query.contains(.init(name: "id", value: "m5")) { return m5Page }
                if query.contains(.init(name: "id", value: "new-event")) {
                    return newEventPage(boundTo: pendingKey)
                }
                return emptyYouTubePage()
            case ("PUT", let p) where p.hasSuffix("/liveBroadcasts"):
                // Echo the update; it already has the resource's shape.
                return .init(data: request.httpBody ?? Data(), statusCode: 200)
            case ("POST", let p) where p.hasSuffix("/liveBroadcasts"):
                return broadcastResourceResponse(status: "created", bound: false)
            case ("POST", let p) where p.hasSuffix("/liveBroadcasts/bind"):
                // Bound to the requested key (always stream-1 before match keys).
                let key = query.first { $0.name == "streamId" }?.value ?? "stream-1"
                var object = try! JSONSerialization.jsonObject(
                    with: broadcastResourceResponse(status: "ready", bound: true).data) as! [String: Any]
                var details = object["contentDetails"] as! [String: Any]
                details["boundStreamId"] = key
                object["contentDetails"] = details
                return .init(data: try! JSONSerialization.data(withJSONObject: object), statusCode: 200)
            case ("POST", let p) where p.hasSuffix("/thumbnails/set"):
                return .init(data: Data(), statusCode: 200)
            case ("GET", let p) where p.hasSuffix("/playlistItems"):
                return emptyYouTubePage()
            case ("POST", let p) where p.hasSuffix("/playlistItems"):
                return .init(data: Data(#"{"id":"playlist-item"}"#.utf8), statusCode: 200)
            case ("DELETE", let p) where p.hasSuffix("/playlistItems"):
                return .init(data: Data(), statusCode: deleteStatus)
            default:
                return .init(data: Data(), statusCode: 418)
            }
        }
        service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(),
                                 discoveryCache: cache, now: { plannedFixtureNow })
        let resource = try! JSONDecoder().decode(
            YouTubeBroadcastResource.self, from: JSONSerialization.data(withJSONObject: plannedM5()))
        let details = PlannedStreamDetails(broadcast: resource.broadcast!, playlistId: nil)
        selection = PlannedStreamSelection(
            kind: .planned, broadcastId: "m5", streamId: "stream-1", scheduledStartTime: today,
            loaded: details, edited: details, loadedMembership: nil, thumbnailChanged: false
        )
    }

    func start(_ selection: PlannedStreamSelection, thumbnail: Data? = nil) async throws -> YouTubeStreamingPreparation {
        try await service.prepareForStreaming(
            streamKey: "test-key", preferences: setupPreferences(), thumbnailData: Data([0x01]),
            plannedSelection: selection, plannedThumbnail: thumbnail, calendar: plannedFixtureCalendar
        )
    }
}

private actor RoutingYouTubeAPITransport: YouTubeAPITransport {
    private let route: @Sendable (URLRequest) -> YouTubeAPIResponse
    private(set) var requests: [URLRequest] = []

    init(route: @escaping @Sendable (URLRequest) -> YouTubeAPIResponse) {
        self.route = route
    }

    func response(for request: URLRequest) async throws -> YouTubeAPIResponse {
        requests.append(request)
        return route(request)
    }
}

// MARK: - Match keys

extension YouTubeServiceTests {
    @Test @MainActor
    func assignMovesSharedAndUnboundMatchesAndKeepsAloneOnes() async throws {
        let fixture = MatchKeyFixture(upcoming: [
            matchKeyBroadcast("m1", stream: "studio-default"),
            matchKeyBroadcast("m2", stream: "studio-default"),
            matchKeyBroadcast("m3", stream: "key-1"),
            matchKeyBroadcast("m4", stream: nil),
        ], streams: [
            matchKeyStream("studio-default", title: "Default stream key"),
            matchKeyStream("key-1", title: "Tubeist match 1"),
            matchKeyStream("key-2", title: "Tubeist match 2"),
        ])

        let result = try await fixture.service.assignMatchKeys()

        #expect(result == MatchKeyAssignmentResult(total: 4, moved: 3, alreadySet: 1, failures: []))
        let binds = await fixture.binds()
        #expect(binds.map(\.broadcast) == ["m1", "m2", "m4"])
        #expect(binds[0].stream == "key-2")
        let created = await fixture.createdStreams()
        #expect(created.map(\.title) == ["Tubeist match 3", "Tubeist match 4"])
        for body in created.map(\.body) {
            #expect((body["cdn"] as? [String: Any])?["ingestionType"] as? String == "hls")
            #expect((body["contentDetails"] as? [String: Any])?["isReusable"] as? Bool == true)
        }
        #expect(binds[1].stream == created[0].id)
        #expect(binds[2].stream == created[1].id)
        let streamPosts = await fixture.transport.requests.filter {
            $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/liveStreams") == true
        }
        #expect(streamPosts.allSatisfy { queryItems(in: $0).contains(.init(name: "part", value: "snippet,cdn,contentDetails")) })
        let lists = await fixture.transport.requests.filter { $0.httpMethod == "GET" }.map(queryItems(in:))
        #expect(lists.contains { $0.contains(.init(name: "broadcastStatus", value: "upcoming")) && $0.contains(.init(name: "broadcastType", value: "all")) })
        #expect(lists.contains { $0.contains(.init(name: "mine", value: "true")) && $0.contains(.init(name: "part", value: "snippet,cdn,status")) })
    }

    @Test @MainActor
    func assignReusesFreeKeysAcrossPagesBeforeCreatingOne() async throws {
        let fixture = MatchKeyFixture(upcoming: [
            matchKeyBroadcast("m1", stream: "studio-default"),
            matchKeyBroadcast("m2", stream: "key-1"),
        ], streams: [
            matchKeyStream("studio-default", title: "Default stream key"),
            matchKeyStream("key-1", title: "Tubeist match 1"),
            matchKeyStream("key-3", title: "Tubeist match 3"),
            matchKeyStream("key-2", title: "Tubeist match 2", streamStatus: "active"),
        ], pageSize: 2)

        let result = try await fixture.service.assignMatchKeys()

        #expect(result.failures.isEmpty)
        // key-2 is still receiving video, so the free key is key-3 (on page 2).
        #expect(await fixture.binds().map(\.stream) == ["key-3"])
        #expect(await fixture.createdStreams().isEmpty)
    }

    @Test @MainActor
    func assignNeverRebindsTubeistsPersistentOrActiveBroadcasts() async throws {
        let scope = YouTubeDiscoveryCache.scope(refreshToken: "refresh-token")
        let cache = YouTubeDiscoveryCache()
        cache.setID("remembered", kind: "createdBroadcast", for: YouTubeDiscoveryCache.key(scope: scope, streamKey: "phone-key"))
        let fixture = MatchKeyFixture(upcoming: [
            matchKeyBroadcast("own", stream: "studio-default",
                              published: "2026-11-01T11:59:50Z", scheduled: "2026-11-01T12:00:00Z"),
            matchKeyBroadcast("remembered", stream: "studio-default"),
            matchKeyBroadcast("persistent", stream: "studio-default", persistent: true),
            matchKeyBroadcast("ended", stream: "studio-default", status: "complete"),
            matchKeyBroadcast("m1", stream: "studio-default"),
        ], active: [
            matchKeyBroadcast("live", stream: "studio-default", status: "live"),
        ], streams: [
            matchKeyStream("studio-default", title: "Default stream key"),
        ], cache: cache)

        let result = try await fixture.service.assignMatchKeys()

        #expect(await fixture.binds().map(\.broadcast) == ["m1"])
        #expect(result == MatchKeyAssignmentResult(total: 1, moved: 1, alreadySet: 0, failures: []))
    }

    @Test @MainActor
    func verificationMovesAMatchThatEndedUpSharingAKey() async throws {
        let fixture = MatchKeyFixture(upcoming: [
            matchKeyBroadcast("m1", stream: "studio-default"),
        ], streams: [
            matchKeyStream("studio-default", title: "Default stream key"),
            matchKeyStream("key-2", title: "Tubeist match 2"),
        ], onRelist: { listing, upcoming in
            // Another phone put m9 on the same key at the same moment.
            guard listing == 2 else { return upcoming }
            return upcoming + [matchKeyBroadcast("m9", stream: "key-2")]
        })

        let result = try await fixture.service.assignMatchKeys()

        let binds = await fixture.binds()
        #expect(binds.count == 2)
        #expect(binds[0].broadcast == "m1" && binds[0].stream == "key-2")
        #expect(["m1", "m9"].contains(binds[1].broadcast))
        #expect(binds[1].stream != "key-2")
        #expect(result.failures.isEmpty)
        #expect(await fixture.upcomingListings() == 3)
    }

    @Test @MainActor
    func assignReportsPerMatchFailureAndContinues() async throws {
        let fixture = MatchKeyFixture(upcoming: [
            matchKeyBroadcast("m1", stream: "studio-default"),
            matchKeyBroadcast("m2", stream: "studio-default"),
        ], streams: [
            matchKeyStream("studio-default", title: "Default stream key"),
            matchKeyStream("key-1", title: "Tubeist match 1"),
        ], bindStatus: ["m2": 403])

        let result = try await fixture.service.assignMatchKeys()

        #expect(result.failures == [MatchKeyFailure(title: "m2 title", reason: "HTTP 403")])
        #expect(await fixture.boundStream(of: "m1") == "key-1")
        #expect(result.moved == 1)
        #expect(result.summary.contains("Could not give 'm2 title' its own key:"))
        #expect(result.summary.split(separator: "\n").last == "Could not give 'm2 title' its own key: HTTP 403.")
    }

    @Test @MainActor
    func assignThrowsWhenSignedOut() async throws {
        let fixture = MatchKeyFixture(upcoming: [], streams: [], tokenStore: MemoryYouTubeTokenStore(
            accessToken: nil, refreshToken: nil, expiry: nil))

        await #expect(throws: YouTubeError.notSignedIn) {
            _ = try await fixture.service.assignMatchKeys()
        }
        #expect(await fixture.transport.requests.isEmpty)
    }

    @Test
    func summaryCopy() {
        #expect(MatchKeyAssignmentResult(total: 12, moved: 3, alreadySet: 9, failures: []).summary
                == "12 matches, each with its own key. 3 moved, 9 already set up.")
    }

    @Test @MainActor
    func assignNeverLogsOrReturnsSecretKeys() async throws {
        let captured = CapturedYouTubeDiagnostics()
        let fixture = MatchKeyFixture(upcoming: [
            matchKeyBroadcast("m1", stream: "studio-default"),
            matchKeyBroadcast("m2", stream: "studio-default"),
            matchKeyBroadcast("m3", stream: nil),
        ], streams: [
            matchKeyStream("studio-default", title: "Default stream key"),
            matchKeyStream("key-1", title: "Tubeist match 1"),
        ], bindStatus: ["m2": 500], diagnostics: captured.diagnostics)

        let result = try await fixture.service.assignMatchKeys()

        #expect(!result.failures.isEmpty)
        let texts = [result.summary, captured.text] + result.failures.map(\.reason)
        #expect(!captured.text.isEmpty)
        #expect(texts.allSatisfy { !$0.contains("secret-") })
    }

    @Test @MainActor
    func moveToOwnMatchKeysMovesOnlyTheGivenMatches() async throws {
        let fixture = MatchKeyFixture(upcoming: [
            matchKeyBroadcast("m1", stream: "studio-default"),
            matchKeyBroadcast("m2", stream: "studio-default"),
        ], streams: [
            matchKeyStream("studio-default", title: "Default stream key"),
            matchKeyStream("key-1", title: "Tubeist match 1"),
        ])

        try await fixture.service.moveToOwnMatchKeys(broadcastIDs: ["m2"])

        #expect(await fixture.binds().map(\.broadcast) == ["m2"])
        #expect(await fixture.boundStream(of: "m2") == "key-1")
    }

    @Test @MainActor
    func moveToOwnMatchKeysThrowsOnFirstFailure() async throws {
        let fixture = MatchKeyFixture(upcoming: [
            matchKeyBroadcast("m1", stream: "studio-default"),
            matchKeyBroadcast("m2", stream: "studio-default"),
        ], streams: [
            matchKeyStream("studio-default", title: "Default stream key"),
            matchKeyStream("key-1", title: "Tubeist match 1"),
            matchKeyStream("key-2", title: "Tubeist match 2"),
        ], bindStatus: ["m1": 403])

        await #expect(throws: YouTubeError.self) {
            try await fixture.service.moveToOwnMatchKeys(broadcastIDs: ["m1", "m2"])
        }
        #expect(await fixture.binds().map(\.broadcast) == ["m1"])
    }

    @Test @MainActor
    func rememberedCreatedBroadcastIDsCoverEveryKeyInTheScope() {
        let cache = YouTubeDiscoveryCache()
        let scope = YouTubeDiscoveryCache.scope(refreshToken: "refresh-token")
        let other = YouTubeDiscoveryCache.scope(refreshToken: "other-token")
        cache.setID("a", kind: "createdBroadcast", for: YouTubeDiscoveryCache.key(scope: scope, streamKey: "key-a"))
        cache.setID("b", kind: "createdBroadcast", for: YouTubeDiscoveryCache.key(scope: scope, streamKey: "key-b"))
        cache.setID("s", kind: "stream", for: YouTubeDiscoveryCache.key(scope: scope, streamKey: "key-a"))
        cache.setID("c", kind: "createdBroadcast", for: YouTubeDiscoveryCache.key(scope: other, streamKey: "key-a"))

        #expect(cache.rememberedCreatedBroadcastIDs(scope: scope) == ["a", "b"])
    }
}

/// A planned broadcast as `liveBroadcasts.list` returns it; title is "<id> title".
private func matchKeyBroadcast(
    _ id: String, stream: String?, status: String = "ready",
    published: String = "2026-10-20T10:00:00Z", scheduled: String = "2026-11-01T12:00:00Z",
    persistent: Bool = false
) -> [String: Any] {
    var details: [String: Any] = ["enableAutoStart": true, "enableAutoStop": true]
    details["boundStreamId"] = stream
    return [
        "id": id,
        "snippet": ["title": "\(id) title", "publishedAt": published, "scheduledStartTime": scheduled,
                    "isDefaultBroadcast": persistent],
        "status": ["privacyStatus": "unlisted", "lifeCycleStatus": status],
        "contentDetails": details,
    ]
}

/// A `liveStreams.list` item whose secret key is "secret-<id>".
private func matchKeyStream(_ id: String, title: String, streamStatus: String = "ready") -> [String: Any] {
    [
        "id": id,
        "snippet": ["title": title],
        "cdn": ["ingestionType": "hls", "ingestionInfo": [
            "streamName": "secret-\(id)",
            "ingestionAddress": "https://a.upload.youtube.com/http_upload_hls?cid=secret-\(id)&file=",
        ]],
        "status": ["streamStatus": streamStatus],
    ]
}

/// A small in-memory channel: binds and stream inserts change what later lists return.
private final class MatchKeyChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var upcoming: [[String: Any]]
    private let active: [[String: Any]]
    private var streams: [[String: Any]]
    private let pageSize: Int
    private let bindStatus: [String: Int]
    private let onRelist: @Sendable (Int, [[String: Any]]) -> [[String: Any]]
    private var listings = 0
    private var created = 0

    init(upcoming: [[String: Any]], active: [[String: Any]], streams: [[String: Any]], pageSize: Int,
         bindStatus: [String: Int], onRelist: @escaping @Sendable (Int, [[String: Any]]) -> [[String: Any]]) {
        self.upcoming = upcoming
        self.active = active
        self.streams = streams
        self.pageSize = pageSize
        self.bindStatus = bindStatus
        self.onRelist = onRelist
    }

    var upcomingListings: Int { lock.withLock { listings } }

    func boundStream(of id: String) -> String? {
        lock.withLock {
            (upcoming.first { $0["id"] as? String == id }?["contentDetails"] as? [String: Any])?["boundStreamId"] as? String
        }
    }

    func respond(to request: URLRequest) -> YouTubeAPIResponse {
        lock.withLock {
            let path = request.url?.path ?? ""
            let query = queryItems(in: request)
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            switch (request.httpMethod ?? "GET", path) {
            case ("GET", let p) where p.hasSuffix("/liveStreams"):
                return page(streams, token: value("pageToken"))
            case ("GET", let p) where p.hasSuffix("/liveBroadcasts"):
                if value("broadcastStatus") == "active" { return page(active, token: nil) }
                if value("broadcastStatus") == "upcoming" {
                    if value("pageToken") == nil {
                        listings += 1
                        upcoming = onRelist(listings, upcoming)
                    }
                    return page(upcoming, token: value("pageToken"))
                }
                return page([], token: nil)
            case ("POST", let p) where p.hasSuffix("/liveStreams"):
                created += 1
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                let title = (body?["snippet"] as? [String: Any])?["title"] as? String ?? ""
                let stream = matchKeyStream("created-\(created)", title: title)
                streams.append(stream)
                return .init(data: try! JSONSerialization.data(withJSONObject: stream), statusCode: 200)
            case ("POST", let p) where p.hasSuffix("/liveBroadcasts/bind"):
                guard let id = value("id"), let streamId = value("streamId"),
                      let index = upcoming.firstIndex(where: { $0["id"] as? String == id }) else {
                    return .init(data: Data(), statusCode: 404)
                }
                if let status = bindStatus[id] {
                    return .init(data: Data(#"{"error":{"message":"denied"}}"#.utf8), statusCode: status)
                }
                var details = upcoming[index]["contentDetails"] as? [String: Any] ?? [:]
                details["boundStreamId"] = streamId
                upcoming[index]["contentDetails"] = details
                return .init(data: try! JSONSerialization.data(withJSONObject: upcoming[index]), statusCode: 200)
            default:
                return .init(data: Data(), statusCode: 418)
            }
        }
    }

    private func page(_ items: [[String: Any]], token: String?) -> YouTubeAPIResponse {
        let start = token.flatMap(Int.init) ?? 0
        let end = min(items.count, start + pageSize)
        var object: [String: Any] = ["items": Array(items[start..<end])]
        if end < items.count { object["nextPageToken"] = String(end) }
        return .init(data: try! JSONSerialization.data(withJSONObject: object), statusCode: 200)
    }
}

@MainActor private struct MatchKeyFixture {
    let channel: MatchKeyChannel
    let transport: RoutingYouTubeAPITransport
    let service: YouTubeService

    init(
        upcoming: [[String: Any]], active: [[String: Any]] = [], streams: [[String: Any]],
        pageSize: Int = 50, bindStatus: [String: Int] = [:], cache: YouTubeDiscoveryCache = YouTubeDiscoveryCache(),
        tokenStore: MemoryYouTubeTokenStore = validMemoryTokenStore(),
        diagnostics: YouTubeDiagnostics = YouTubeDiagnostics(),
        onRelist: @escaping @Sendable (Int, [[String: Any]]) -> [[String: Any]] = { $1 }
    ) {
        let channel = MatchKeyChannel(upcoming: upcoming, active: active, streams: streams, pageSize: pageSize,
                                      bindStatus: bindStatus, onRelist: onRelist)
        self.channel = channel
        transport = RoutingYouTubeAPITransport { channel.respond(to: $0) }
        service = YouTubeService(transport: transport, tokenStore: tokenStore, discoveryCache: cache,
                                 now: { plannedFixtureNow }, diagnostics: diagnostics)
    }

    func binds() async -> [(broadcast: String, stream: String)] {
        await transport.requests.filter { $0.url?.path.hasSuffix("/liveBroadcasts/bind") == true }.map { request in
            let query = queryItems(in: request)
            return (query.first { $0.name == "id" }?.value ?? "", query.first { $0.name == "streamId" }?.value ?? "")
        }
    }

    func createdStreams() async -> [(id: String, title: String, body: [String: Any])] {
        let posts = await transport.requests.filter {
            $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/liveStreams") == true
        }
        return posts.enumerated().map { index, request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            return ("created-\(index + 1)", (body["snippet"] as? [String: Any])?["title"] as? String ?? "", body)
        }
    }

    func boundStream(of id: String) async -> String? { channel.boundStream(of: id) }
    func upcomingListings() async -> Int { channel.upcomingListings }
}

// MARK: - Start safety checks

extension YouTubeServiceTests {
    @Test @MainActor
    func plannedPickFollowsTheMatchToItsNewKey() async throws {
        let fixture = PlannedStartFixture()
        #expect(fixture.selection.streamId == "stream-1")

        let preparation = try await fixture.start(fixture.selection)

        #expect(preparation.endpoint == (try YouTubeHLSEndpoint(URL(string: matchKeyOneAddress)!)))
        #expect(preparation.healthTarget.streamID == "match-1")
        let methods = await fixture.transport.requests.map(\.httpMethod)
        #expect(!methods.contains { ["PUT", "POST", "DELETE"].contains($0) })
    }

    @Test @MainActor
    func plannedPickOnThePhoneKeyOffersOwnKey() async throws {
        let fixture = PlannedStartFixture(m5: plannedM5())

        await #expect(throws: YouTubeError.keyConflict(YouTubeKeyConflict(
            kind: .plannedNeedsOwnKey, matchTitle: "Match 5", otherTitle: nil, broadcastIDsToMove: ["m5"]))) {
            _ = try await fixture.start(fixture.selection)
        }
        let methods = await fixture.transport.requests.map(\.httpMethod)
        #expect(!methods.contains { ["PUT", "POST", "DELETE"].contains($0) })
    }

    @Test @MainActor
    func plannedPickSharingAKeyOffersOwnKey() async throws {
        let fixture = PlannedStartFixture(upcoming: keyCheckPage([
            plannedM5(stream: "match-1"), keyCheckItem("m6", title: "Match 6", stream: "match-1"),
        ]))
        let conflict = YouTubeKeyConflict(
            kind: .plannedNeedsOwnKey, matchTitle: "Match 5", otherTitle: "Match 6", broadcastIDsToMove: ["m5"])

        await #expect(throws: YouTubeError.keyConflict(conflict)) {
            _ = try await fixture.start(fixture.selection)
        }
        #expect(conflict.prompt == "'Match 5' shares its key with 'Match 6'. Give this match its own key?")
        #expect(YouTubeError.keyConflict(conflict).errorDescription == conflict.prompt)
        let methods = await fixture.transport.requests.map(\.httpMethod)
        #expect(!methods.contains { ["PUT", "POST", "DELETE"].contains($0) })
    }

    @Test @MainActor
    func plannedPickBlockedByATubeistBroadcast() async throws {
        let fixture = PlannedStartFixture(upcoming: keyCheckPage([
            plannedM5(stream: "match-1"),
            keyCheckItem("manual", title: "Manual stream", stream: "match-1", tubeistOwn: true),
        ]))

        await #expect(throws: YouTubeError.keyBlocked("Manual stream")) {
            _ = try await fixture.start(fixture.selection)
        }
        let methods = await fixture.transport.requests.map(\.httpMethod)
        #expect(!methods.contains { ["PUT", "POST", "DELETE"].contains($0) })
    }

    @Test @MainActor
    func plannedPickRefusedWhileAnotherDeviceStreams() async throws {
        let fixture = PlannedStartFixture(active: keyCheckPage([
            keyCheckItem("elsewhere", title: "Match 5 (phone B)", stream: "match-1", status: "live"),
        ]))

        await #expect(throws: YouTubeError.keyInUse("Match 5")) {
            _ = try await fixture.start(fixture.selection)
        }
        let methods = await fixture.transport.requests.map(\.httpMethod)
        #expect(!methods.contains { ["PUT", "POST", "DELETE"].contains($0) })
    }

    @Test @MainActor
    func plannedPickIgnoresALiveBroadcastOnAnotherKey() async throws {
        let fixture = PlannedStartFixture(active: keyCheckPage([
            keyCheckItem("elsewhere", title: "Other match", stream: "match-2", status: "live"),
        ]))

        let preparation = try await fixture.start(fixture.selection)

        #expect(preparation.broadcast.id == "m5")
    }

    @Test @MainActor
    func recreatedRestartMovesToAFreeKeyWhenItsOldKeyIsTaken() async throws {
        // Match 6 was assigned the ended Match 5's key; Restart must not prompt.
        let fixture = PlannedStartFixture(
            m5: plannedM5(status: "complete", stream: "match-1"),
            upcoming: keyCheckPage([keyCheckItem("m6", title: "Match 6", stream: "match-1")]))

        let preparation = try await fixture.start(fixture.selection.restarting())

        #expect(preparation.broadcast.id == "new-event")
        #expect(preparation.endpoint == (try YouTubeHLSEndpoint(URL(string: matchKeyAddress(2))!)))
        let requests = await fixture.transport.requests
        let bind = try #require(requests.first { $0.url?.path.hasSuffix("/liveBroadcasts/bind") == true })
        #expect(queryItems(in: bind).contains(.init(name: "streamId", value: "match-2")))
        #expect(queryItems(in: bind).contains(.init(name: "id", value: "new-event")))
        #expect(!requests.contains { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/liveStreams") == true })
    }

    @Test @MainActor
    func recreatedRestartCreatesAMatchKeyWhenNoneIsFree() async throws {
        let fixture = PlannedStartFixture(
            m5: plannedM5(status: "complete", stream: "match-1"),
            upcoming: keyCheckPage([keyCheckItem("m6", title: "Match 6", stream: "match-1")]), matchKeys: [1])

        _ = try await fixture.start(fixture.selection.restarting())

        let requests = await fixture.transport.requests
        let create = try #require(requests.first {
            $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/liveStreams") == true
        })
        #expect(try plannedJSONBody(create.httpBody)["snippet"] as? [String: String] == ["title": "Tubeist match 2"])
        let bind = try #require(requests.first { $0.url?.path.hasSuffix("/liveBroadcasts/bind") == true })
        #expect(queryItems(in: bind).contains(.init(name: "streamId", value: "match-2")))
    }

    @Test @MainActor
    func restartRecreatesOnTheEndedBroadcastsMatchKey() async throws {
        let fixture = PlannedStartFixture(m5: plannedM5(status: "complete", stream: "match-1"))

        let preparation = try await fixture.start(fixture.selection.restarting())

        #expect(preparation.endpoint == (try YouTubeHLSEndpoint(URL(string: matchKeyOneAddress)!)))
        let bind = try #require(await fixture.transport.requests.first {
            $0.url?.path.hasSuffix("/liveBroadcasts/bind") == true
        })
        #expect(queryItems(in: bind).contains(.init(name: "streamId", value: "match-1")))
    }

    @Test @MainActor
    func restartOnAStillReadyOriginalDoesNotCountItselfAsAConflict() async throws {
        let fixture = PlannedStartFixture(upcoming: keyCheckPage([plannedM5(stream: "match-1")]))

        let preparation = try await fixture.start(fixture.selection.restarting())

        #expect(preparation.broadcast.id == "m5")
    }

    @Test @MainActor
    func newStreamOffersToMovePlannedMatchesOffThePhoneKey() async throws {
        // The 15:00 scenario: a Studio match with auto-start waits on this phone's key.
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(), studioPlannedPage(status: "ready", title: "15:00 match"),
            matchingStreamPage(), matchingStreamPage(), titledPhoneStreamPage(),
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
        let conflict = YouTubeKeyConflict(
            kind: .newStreamKeyTaken, matchTitle: "Phone A", otherTitle: "15:00 match", broadcastIDsToMove: ["planned-1"])

        await #expect(throws: YouTubeError.keyConflict(conflict)) {
            _ = try await service.prepareForStreaming(streamKey: "test-key", preferences: setupPreferences())
        }
        #expect(conflict.prompt
            == "'15:00 match' is planned on this phone's key and could take over this stream. Move it to its own key?")
        let requests = await transport.requests
        #expect(requests.count == 5)
        #expect(!requests.contains { $0.httpMethod != "GET" })
        #expect(!requests.contains { queryItems(in: $0).contains(.init(name: "id", value: "planned-1")) })
        #expect(!requests.contains { $0.httpBody?.range(of: Data("planned-1".utf8)) != nil })
    }

    @Test @MainActor
    func newStreamConflictNamesThePhoneKeyGenericallyWhenItsTitleIsUnavailable() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(), studioPlannedPage(status: "ready", title: "15:00 match"),
            matchingStreamPage(), matchingStreamPage(), .init(data: Data(), statusCode: 500),
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())

        await #expect(throws: YouTubeError.keyConflict(YouTubeKeyConflict(
            kind: .newStreamKeyTaken, matchTitle: "this phone's key", otherTitle: "15:00 match",
            broadcastIDsToMove: ["planned-1"]))) {
            _ = try await service.prepareForStreaming(streamKey: "test-key", preferences: setupPreferences())
        }
    }

    @Test @MainActor
    func newStreamIsBlockedByAnotherPhonesTubeistBroadcast() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(),
            keyCheckPage([keyCheckItem("foreign", title: "Tubeist live stream", stream: "stream-1", tubeistOwn: true)]),
            matchingStreamPage(), matchingStreamPage(),
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())

        await #expect(throws: YouTubeError.keyBlocked("Tubeist live stream")) {
            _ = try await service.prepareForStreaming(streamKey: "test-key", preferences: setupPreferences())
        }
        #expect(!(await transport.requests).contains { $0.httpMethod != "GET" })
    }

    @Test @MainActor
    func newStreamStillResumesItsOwnLiveBroadcast() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            studioPlannedPage(status: "live", id: "active"), matchingStreamPage(),
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(),
                                     discoveryCache: createdBroadcastCache("active"))

        await #expect(throws: YouTubeError.broadcastNotReady("live")) {
            _ = try await service.prepareForStreaming(streamKey: "test-key", preferences: setupPreferences())
        }
        // The same two lookups as before the key checks; nothing else.
        #expect(await transport.requests.map(\.httpMethod) == ["GET", "GET"])
    }

    @Test @MainActor
    func newStreamWithACleanKeyIsUnchanged() async throws {
        // A planned match on another key is not a conflict, and the checks reuse
        // the broadcast pages discovery already fetched.
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(), studioPlannedPage(status: "ready", stream: "stream-2"), otherKeyStreamPage(),
            matchingStreamPage(),
            broadcastResourceResponse(status: "created", bound: false), broadcastResourceResponse(status: "ready", bound: true),
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())

        let preparation = try await service.prepareForStreaming(streamKey: "test-key", preferences: setupPreferences())

        #expect(preparation.broadcast.id == "new-event")
        let requests = await transport.requests
        try #require(requests.map(\.httpMethod) == ["GET", "GET", "GET", "GET", "POST", "POST"])
        #expect(queryItems(in: requests[5]).contains(.init(name: "streamId", value: "stream-1")))
    }

    @Test @MainActor
    func newStreamListsUpcomingAgainWhenDiscoveryStoppedBeforeTheLastPage() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(), currentBroadcastPage(nextPageToken: "p2"), matchingStreamPage(),
            currentBroadcastPage(nextPageToken: "p2"), studioPlannedPage(status: "ready", title: "15:00 match"),
            titledPhoneStreamPage(),
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(),
                                     discoveryCache: createdBroadcastCache("ready"))

        await #expect(throws: YouTubeError.keyConflict(YouTubeKeyConflict(
            kind: .newStreamKeyTaken, matchTitle: "Phone A", otherTitle: "15:00 match", broadcastIDsToMove: ["planned-1"]))) {
            _ = try await service.prepareForStreaming(streamKey: "test-key", preferences: setupPreferences())
        }
        let requests = await transport.requests
        try #require(requests.count == 6)
        #expect(queryItems(in: requests[4]).contains(.init(name: "pageToken", value: "p2")))
    }

    @Test
    func keyErrorCopy() {
        let alone = YouTubeKeyConflict(
            kind: .plannedNeedsOwnKey, matchTitle: "Match 5", otherTitle: nil, broadcastIDsToMove: ["m5"])
        #expect(YouTubeError.keyInUse("Match 5").errorDescription == "Another device is already streaming to 'Match 5'.")
        #expect(YouTubeError.keyBlocked("Manual stream").errorDescription
            == "'Manual stream' is waiting on this key. End or delete it in YouTube Studio, then try again.")
        #expect(alone.watchMessage == "Open Tubeist on the phone to set up 'Match 5'.")
        #expect(YouTubeError.keyConflict(alone).errorDescription == alone.prompt)
    }

    @Test @MainActor
    func keyErrorsNeverContainSecretKeys() async throws {
        var errors: [Error] = []
        for fixture in [
            PlannedStartFixture(m5: plannedM5()),
            PlannedStartFixture(upcoming: keyCheckPage([
                plannedM5(stream: "match-1"), keyCheckItem("m6", title: "Match 6", stream: "match-1")])),
            PlannedStartFixture(upcoming: keyCheckPage([
                plannedM5(stream: "match-1"),
                keyCheckItem("manual", title: "Manual stream", stream: "match-1", tubeistOwn: true)])),
            PlannedStartFixture(active: keyCheckPage([
                keyCheckItem("elsewhere", title: "Match 5", stream: "match-1", status: "live")])),
        ] {
            do { _ = try await fixture.start(fixture.selection) } catch { errors.append(error) }
        }
        let transport = MockYouTubeAPITransport(responses: [
            emptyYouTubePage(), studioPlannedPage(status: "ready", title: "15:00 match"),
            matchingStreamPage(), matchingStreamPage(), titledPhoneStreamPage(),
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
        do { _ = try await service.prepareForStreaming(streamKey: "test-key") } catch { errors.append(error) }

        #expect(errors.count == 5)
        for error in errors {
            var texts = [String(describing: error), error.localizedDescription]
            if case YouTubeError.keyConflict(let conflict)? = error as? YouTubeError {
                texts += [conflict.prompt, conflict.watchMessage]
            }
            for text in texts {
                #expect(!text.contains("test-key"))
                #expect(!text.contains("match-key-1"))
            }
        }
    }
}

private let matchKeyOneAddress = matchKeyAddress(1)

private func matchKeyAddress(_ number: Int) -> String {
    "https://a.upload.youtube.com/http_upload_hls?cid=match-key-\(number)&file="
}

/// `Tubeist match N` (ID `match-N`) with its own secret key `match-key-N`.
private func matchKeyItem(_ number: Int) -> [String: Any] {
    [
        "id": "match-\(number)", "snippet": ["title": "Tubeist match \(number)"],
        "cdn": ["ingestionType": "hls", "ingestionInfo": [
            "streamName": "match-key-\(number)", "ingestionAddress": matchKeyAddress(number),
        ]],
    ]
}

private func matchKeyPage(_ number: Int) -> YouTubeAPIResponse {
    .init(data: try! JSONSerialization.data(withJSONObject: ["items": [matchKeyItem(number)]]), statusCode: 200)
}

/// `liveStreams.list?mine=true`: the phone key plus the given match keys.
private func channelStreamsPage(_ matchKeys: [Int]) -> YouTubeAPIResponse {
    let phone = (try! JSONSerialization.jsonObject(with: matchingStreamPage().data) as! [String: Any])["items"] as! [Any]
    return .init(data: try! JSONSerialization.data(
        withJSONObject: ["items": phone + matchKeys.map(matchKeyItem)]), statusCode: 200)
}

/// Tubeist's pending "new-event" broadcast, bound to `key`.
private func newEventPage(boundTo key: String) -> YouTubeAPIResponse {
    var object = try! JSONSerialization.jsonObject(
        with: broadcastResourceResponse(status: "ready", bound: true).data) as! [String: Any]
    var details = object["contentDetails"] as! [String: Any]
    details["boundStreamId"] = key
    object["contentDetails"] = details
    return .init(data: try! JSONSerialization.data(withJSONObject: ["items": [object]]), statusCode: 200)
}

private func titledPhoneStreamPage() -> YouTubeAPIResponse {
    .init(data: Data(#"{"items":[{"id":"stream-1","snippet":{"title":"Phone A"},"cdn":{"ingestionType":"hls","ingestionInfo":{"streamName":"test-key","ingestionAddress":"https://a.upload.youtube.com/http_upload_hls?cid=test-key&file="}}}]}"#.utf8), statusCode: 200)
}

private func otherKeyStreamPage() -> YouTubeAPIResponse {
    .init(data: Data(#"{"items":[{"id":"stream-2","cdn":{"ingestionType":"hls","ingestionInfo":{"streamName":"other-key","ingestionAddress":"https://a.upload.youtube.com/http_upload_hls?cid=other-key&file="}}}]}"#.utf8), statusCode: 200)
}

/// An upcoming broadcast with auto-start on. `tubeistOwn` schedules it 10 s
/// after creation, as Tubeist does.
private func keyCheckItem(
    _ id: String, title: String, stream: String, status: String = "ready", tubeistOwn: Bool = false
) -> [String: Any] {
    var snippet: [String: Any] = ["title": title, "scheduledStartTime": ISO8601DateFormatter().string(from: plannedFixtureNow)]
    if tubeistOwn {
        snippet["publishedAt"] = ISO8601DateFormatter().string(from: plannedFixtureNow.addingTimeInterval(-10))
    }
    return [
        "id": id, "snippet": snippet,
        "status": ["privacyStatus": "unlisted", "lifeCycleStatus": status],
        "contentDetails": ["boundStreamId": stream, "enableAutoStart": true],
    ]
}

private func keyCheckPage(_ items: [[String: Any]]) -> YouTubeAPIResponse {
    .init(data: try! JSONSerialization.data(withJSONObject: ["items": items]), statusCode: 200)
}
