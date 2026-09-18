//
//  YouTubeServiceTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct YouTubeServiceTests {
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
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache(), diagnostics: captured.diagnostics)

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
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
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
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
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
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache())
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
            tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache()
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
            tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache()
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
    func settingsDiagnosticsIdentifyAuthorizedChannelAndSuccessfulDiscovery() async throws {
        let captured = CapturedYouTubeDiagnostics()
        let transport = MockYouTubeAPITransport(responses: settingsDiagnosticResponses())
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache(), diagnostics: captured.diagnostics)
        let settings = try await service.loadSettingsConfiguration(forStreamKey: "test-key")
        #expect(settings.broadcast.id == "ready")
        #expect(settings.playlists.isEmpty)
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
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache(), diagnostics: captured.diagnostics)
        await #expect(throws: YouTubeError.apiError(500, "Internal error encountered.")) {
            _ = try await service.loadSettingsConfiguration(forStreamKey: "test-key")
        }
        #expect(captured.text.contains("\(operations[stage].rawValue): HTTP 500"))
        #expect(captured.text.contains("reason=backendError"))
        #expect(captured.entries.contains { $0.1 == .error })
        #expect(!captured.entries.contains { $0.1 == .info })
        #expect(captured.text.contains("authorized channel: Brand channel"))
        #expect(await transport.requestCount == stage + 1)
        #expect(!service.isLoading)
    }

    @Test(arguments: [401, 500]) @MainActor
    func optionalChannelFailureDoesNotBlockSettingsOrRefreshAuthorization(_ status: Int) async throws {
        let captured = CapturedYouTubeDiagnostics()
        var responses = settingsDiagnosticResponses()
        responses[0] = .init(data: Data(#"{"error":{"message":"Channel check failed"}}"#.utf8), statusCode: status)
        let transport = MockYouTubeAPITransport(responses: responses)
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore(), discoveryCache: YouTubeDiscoveryCache(), diagnostics: captured.diagnostics)
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
