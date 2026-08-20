//
//  YouTubeHLSStreamSinkTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct YouTubeHLSStreamSinkTests {
    @Test func remuxesWriterFragmentsWithoutUploadingTheInitializationSegment() async throws {
        let transport = DirectSinkTransport()
        let endpoint = try YouTubeHLSEndpoint(URL(
            string: "https://upload.youtube.com/http_upload_hls?cid=not-a-real-key&file="
        )!)
        let sink = YouTubeHLSStreamSink()
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
        let sink = YouTubeHLSStreamSink()
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

    @Test func finalFragmentUsesParsedTimelineWhenWriterTrackDurationIsShorter() async throws {
        let reader = ISOBMFFReader()
        let initializationData = FMP4Fixture.initialization()
        let mediaData = FMP4Fixture.mediaSegment()
        let initialization = try reader.parseInitializationSegment(initializationData)
        let media = try reader.parseMediaSegment(
            mediaData,
            initialization: initialization
        )
        var muxer = MPEGTransportStreamMuxer()
        let parsedDuration = try muxer.mux(
            media,
            initialization: initialization
        ).duration
        let transport = DirectSinkTransport()
        let endpoint = try YouTubeHLSEndpoint(URL(
            string: "https://upload.youtube.com/http_upload_hls?cid=not-a-real-key&file="
        )!)
        let sink = YouTubeHLSStreamSink()
        try await sink.prepare(
            endpoint: endpoint,
            sessionIdentifier: "final_duration_session",
            userAgent: "Tubeist/Test",
            transport: transport
        )
        await sink.enqueue(Fragment(
            sequence: 0,
            segment: initializationData,
            duration: 0,
            type: .initialization
        ))
        await sink.enqueue(Fragment(
            sequence: 1,
            segment: mediaData,
            duration: max(0.001, parsedDuration - 0.2),
            type: .finalization
        ))
        try await sink.finish(timeout: 2)

        let requests = await transport.requests()
        #expect(requests.count == 2)
        let playlist = String(decoding: requests[0].body, as: UTF8.self)
        let formattedDuration = String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            parsedDuration
        )
        #expect(playlist.contains("#EXTINF:\(formattedDuration),"))
        let metrics = await sink.metrics()
        #expect(metrics.lastAcceptedMediaSequence == 0)
        #expect(metrics.failure == nil)
    }

    @Test func coalescesSplitFinalVideoAndAudioBeforeStopping() async throws {
        let transport = DirectSinkTransport()
        let endpoint = try YouTubeHLSEndpoint(URL(
            string: "https://upload.youtube.com/http_upload_hls?cid=not-a-real-key&file="
        )!)
        let sink = YouTubeHLSStreamSink()
        try await sink.prepare(
            endpoint: endpoint,
            sessionIdentifier: "split_final_session",
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
            segment: FMP4Fixture.mediaSegment(includeAudio: false),
            duration: 0.04,
            type: .finalization
        ))
        await sink.enqueue(Fragment(
            sequence: 2,
            segment: FMP4Fixture.mediaSegment(includeVideo: false),
            duration: 0.03,
            type: .finalization
        ))

        try await sink.finish(timeout: 2)

        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(requests[0].contentType == "application/vnd.apple.mpegurl")
        #expect(requests[1].contentType == "video/mp2t")
        #expect(requests[1].body.first == 0x47)
        let packetPIDs = directSinkPacketPIDs(requests[1].body)
        #expect(packetPIDs.contains(MPEGTransportStreamMuxer.videoPID))
        #expect(packetPIDs.contains(MPEGTransportStreamMuxer.audioPID))
        let metrics = await sink.metrics()
        #expect(metrics.lastAcceptedMediaSequence == 0)
        #expect(metrics.failure == nil)
    }

    @Test func incompleteFinalTrackDoesNotPoisonAlreadyBufferedMedia() async throws {
        let transport = DirectSinkTransport()
        let endpoint = try YouTubeHLSEndpoint(URL(
            string: "https://upload.youtube.com/http_upload_hls?cid=not-a-real-key&file="
        )!)
        let sink = YouTubeHLSStreamSink()
        try await sink.prepare(
            endpoint: endpoint,
            sessionIdentifier: "incomplete_final_session",
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
        await sink.enqueue(Fragment(
            sequence: 2,
            segment: FMP4Fixture.mediaSegment(
                sequence: 8,
                videoDecodeTime: 4_000,
                audioDecodeTime: 2_080,
                includeVideo: false
            ),
            duration: 0.03,
            type: .finalization
        ))

        try await sink.finish(timeout: 2)

        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(requests[1].contentType == "video/mp2t")
        let metrics = await sink.metrics()
        #expect(metrics.lastAcceptedMediaSequence == 0)
        #expect(metrics.failure == nil)
    }

    @Test func shutdownReportsPackagingFailureInsteadOfClaimingTheSinkWasNotPrepared() async throws {
        let transport = DirectSinkTransport()
        let endpoint = try YouTubeHLSEndpoint(URL(
            string: "https://upload.youtube.com/http_upload_hls?cid=not-a-real-key&file="
        )!)
        let sink = YouTubeHLSStreamSink()
        try await sink.prepare(
            endpoint: endpoint,
            sessionIdentifier: "malformed_shutdown_session",
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
            segment: Data([0, 1, 2, 3]),
            duration: 1,
            type: .separable
        ))

        do {
            try await sink.finish(timeout: 2)
            Issue.record("Expected malformed media to fail shutdown")
        } catch let error as YouTubeHLSPackagingError {
            if case .packagingFailed = error {
                // Expected: the public error is accurate and contains no URL.
            } else {
                Issue.record("Unexpected shutdown error: \(error)")
            }
        }
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
        let sink = YouTubeHLSStreamSink()
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
        } catch let error as YouTubeHLSPackagingError {
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

private func directSinkPacketPIDs(_ data: Data) -> [UInt16] {
    guard data.count.isMultiple(of: MPEGTransportStreamMuxer.packetSize) else {
        return []
    }
    return stride(from: 0, to: data.count, by: MPEGTransportStreamMuxer.packetSize).compactMap {
        guard data[$0] == 0x47 else { return nil }
        return (UInt16(data[$0 + 1] & 0x1f) << 8) | UInt16(data[$0 + 2])
    }
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
