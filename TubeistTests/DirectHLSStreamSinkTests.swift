//
//  DirectHLSStreamSinkTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct DirectHLSStreamSinkTests {
    @Test func remuxesWriterFragmentsWithoutUploadingTheInitializationSegment() async throws {
        let transport = DirectSinkTransport()
        let endpoint = try YouTubeHLSEndpoint(URL(
            string: "https://upload.youtube.com/http_upload_hls?cid=not-a-real-key&file="
        )!)
        let sink = DirectHLSStreamSink()
        try await sink.prepare(
            endpoint: endpoint,
            sessionIdentifier: "integration_session",
            userAgent: "Tubeist/Test",
            transport: transport
        )
        await sink.enqueue(Fragment(
            sequence: 0,
            segment: FMP4Fixture.initialization(),
            duration: 0,
            type: .initialization
        ))
        await sink.enqueue(Fragment(
            sequence: 1,
            segment: FMP4Fixture.mediaSegment(),
            duration: 0,
            type: .separable
        ))
        try await sink.finish(timeout: 2)

        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(requests[0].contentType == "application/vnd.apple.mpegurl")
        #expect(requests[1].contentType == "video/mp2t")
        #expect(requests[1].body.count.isMultiple(of: MPEGTransportStreamMuxer.packetSize))
        #expect(requests[1].body.first == 0x47)
        #expect(!requests.contains { $0.body == FMP4Fixture.initialization() })
        let metrics = await sink.metrics()
        #expect(metrics.lastAcceptedMediaSequence == 0)
        #expect(metrics.failure == nil)
    }

    @Test func replacingAnInFlightSessionCannotPoisonTheNewSession() async throws {
        let slowTransport = SlowDirectSinkTransport()
        let newTransport = DirectSinkTransport()
        let endpoint = try YouTubeHLSEndpoint(URL(
            string: "https://upload.youtube.com/http_upload_hls?cid=not-a-real-key&file="
        )!)
        let sink = DirectHLSStreamSink()
        try await sink.prepare(
            endpoint: endpoint,
            sessionIdentifier: "old_session",
            userAgent: "Tubeist/Test",
            transport: slowTransport
        )
        await sink.enqueue(Fragment(
            sequence: 0,
            segment: FMP4Fixture.initialization(),
            duration: 0,
            type: .initialization
        ))
        await sink.enqueue(Fragment(
            sequence: 1,
            segment: FMP4Fixture.mediaSegment(),
            duration: 0,
            type: .separable
        ))
        try await slowTransport.waitUntilRequested()

        try await sink.prepare(
            endpoint: endpoint,
            sessionIdentifier: "new_session",
            userAgent: "Tubeist/Test",
            transport: newTransport
        )
        await sink.enqueue(Fragment(
            sequence: 0,
            segment: FMP4Fixture.initialization(),
            duration: 0,
            type: .initialization
        ))
        await sink.enqueue(Fragment(
            sequence: 1,
            segment: FMP4Fixture.mediaSegment(),
            duration: 0,
            type: .separable
        ))
        try await sink.finish(timeout: 2)

        let requests = await newTransport.requests()
        #expect(requests.count == 2)
        #expect(requests[1].contentType == "video/mp2t")
        let metrics = await sink.metrics()
        #expect(metrics.lastAcceptedMediaSequence == 0)
        #expect(metrics.failure == nil)
    }

    @Test func sustainedNetworkStallKeepsTheQueueAndShutdownBounded() async throws {
        let reader = ISOBMFFReader()
        let initialization = try reader.parseInitializationSegment(FMP4Fixture.initialization())
        let media = try reader.parseMediaSegment(
            FMP4Fixture.mediaSegment(),
            initialization: initialization
        )
        var muxer = MPEGTransportStreamMuxer()
        let fragmentDuration = try muxer.mux(
            media,
            initialization: initialization
        ).duration
        let transport = BlockingDirectSinkTransport()
        let endpoint = try YouTubeHLSEndpoint(URL(
            string: "https://upload.youtube.com/http_upload_hls?cid=not-a-real-key&file="
        )!)
        let sink = DirectHLSStreamSink()
        try await sink.prepare(
            endpoint: endpoint,
            sessionIdentifier: "bounded_session",
            userAgent: "Tubeist/Test",
            transport: transport
        )
        await sink.enqueue(Fragment(
            sequence: 0,
            segment: FMP4Fixture.initialization(),
            duration: 0,
            type: .initialization
        ))
        await sink.enqueue(Fragment(
            sequence: 1,
            segment: FMP4Fixture.mediaSegment(),
            duration: fragmentDuration,
            type: .separable
        ))
        try await transport.waitUntilRequested()
        for sequence in 2..<12 {
            await sink.enqueue(Fragment(
                sequence: sequence,
                segment: FMP4Fixture.mediaSegment(),
                duration: fragmentDuration,
                type: .separable
            ))
        }

        let stalledMetrics = await sink.metrics()
        #expect(stalledMetrics.queuedFragments <= 6)
        #expect(stalledMetrics.droppedFragments >= 5)
        #expect(stalledMetrics.queuedDuration <= fragmentDuration * 6 + 0.001)

        do {
            try await sink.finish(timeout: 0.05)
            Issue.record("Expected the stalled sink to hit its shutdown deadline")
        } catch let error as DirectHLSStreamError {
            if case .shutdownTimedOut = error {
                // Expected.
            } else {
                Issue.record("Unexpected direct-sink shutdown error: \(error)")
            }
        }
        let stoppedMetrics = await sink.metrics()
        #expect(stoppedMetrics.queuedFragments == 0)
    }
}

private struct DirectSinkRequest: Sendable {
    let contentType: String?
    let body: Data
}

private actor DirectSinkTransport: YouTubeHLSHTTPTransport {
    private var sent: [DirectSinkRequest] = []

    func send(_ request: URLRequest, body: Data) -> YouTubeHLSHTTPResponse {
        sent.append(DirectSinkRequest(
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            body: body
        ))
        return YouTubeHLSHTTPResponse(statusCode: 200)
    }

    func invalidate() {}

    func requests() -> [DirectSinkRequest] {
        sent
    }
}

private actor SlowDirectSinkTransport: YouTubeHLSHTTPTransport {
    private var requested = false

    func send(_ request: URLRequest, body: Data) async throws -> YouTubeHLSHTTPResponse {
        requested = true
        try await Task.sleep(for: .milliseconds(100))
        return YouTubeHLSHTTPResponse(statusCode: 200)
    }

    func invalidate() {}

    func waitUntilRequested() async throws {
        for _ in 0..<1_000 {
            if requested {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw BlockingTransportError.requestNeverStarted
    }
}

private enum BlockingTransportError: Error {
    case invalidated
    case requestNeverStarted
}

private actor BlockingDirectSinkTransport: YouTubeHLSHTTPTransport {
    private var requestCount = 0
    private var continuations: [CheckedContinuation<YouTubeHLSHTTPResponse, Error>] = []

    func send(_ request: URLRequest, body: Data) async throws -> YouTubeHLSHTTPResponse {
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func invalidate() {
        let pending = continuations
        continuations.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume(throwing: BlockingTransportError.invalidated) }
    }

    func waitUntilRequested() async throws {
        for _ in 0..<1_000 {
            if requestCount > 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw BlockingTransportError.requestNeverStarted
    }
}
