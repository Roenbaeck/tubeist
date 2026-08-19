//
//  YouTubeServiceTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct YouTubeServiceTests {
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
