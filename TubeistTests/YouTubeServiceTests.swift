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
}

private func streamItem(
    id: String,
    key: String,
    type: String,
    address: String,
    backupAddress: String? = nil
) -> [String: Any] {
    var ingestionInfo: [String: Any] = [
        "streamName": key,
        "ingestionAddress": address,
    ]
    if let backupAddress {
        ingestionInfo["backupIngestionAddress"] = backupAddress
    }
    return [
        "id": id,
        "cdn": [
            "ingestionType": type,
            "ingestionInfo": ingestionInfo,
        ],
    ]
}

private func streamsResponse(_ items: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["items": items], options: [.sortedKeys])
}
