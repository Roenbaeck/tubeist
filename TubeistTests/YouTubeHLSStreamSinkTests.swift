//
//  YouTubeHLSStreamSinkTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

private let successfulSinkShutdownTimeout: TimeInterval = 10

struct YouTubeHLSStreamSinkTests {
    @Test func drainedRecoveryClearsBufferMetricsAndDoesNotDelayTheNextFreshSegment() async throws {
        let clock = SinkUploadClock()
        let transport = SerialSinkTransport(clock: clock, uploadSeconds: 0.2)
        let sink = YouTubeHLSStreamSink()
        try await sink.prepare(endpoint: .manualPrimary(streamKey: "test"),
                               sessionIdentifier: "recovery_idle", userAgent: "Tubeist/Test",
                               transport: transport, sleeper: { _ in },
                               uploadNow: { clock.now() })
        await sink.enqueue(Fragment(sequence: 0, segment: directSentinel(0), duration: 2, container: .mpegTransportStream))
        try await transport.waitUntilRequested()
        clock.transfer(5) // Capture continues while the first request is stalled.
        for sequence in 1...3 {
            await sink.enqueue(Fragment(sequence: sequence, segment: directSentinel(UInt8(sequence)),
                                        duration: 2, container: .mpegTransportStream))
        }
        #expect(await sink.metrics().queuedFragments == 4)
        await transport.releaseFirstRequest()
        try await waitForIdle(sink)
        #expect(await sink.metrics().queuedDuration == 0)
        #expect(await transport.media.count == 4)

        clock.transfer(0.25)
        let freshArrival = clock.now()
        await sink.enqueue(Fragment(sequence: 4, segment: directSentinel(4), duration: 2, container: .mpegTransportStream))
        try await waitForIdle(sink)
        #expect(await transport.media.last?.startedAt == freshArrival)
        #expect(await transport.media.map(\.body) == (0...4).map { directSentinel(UInt8($0)) })
        #expect(await sink.metrics().queuedFragments == 0)
        #expect(await sink.metrics().droppedFragments == 0)
        #expect(try await sink.finish(timeout: successfulSinkShutdownTimeout))
    }

    private func waitForIdle(_ sink: YouTubeHLSStreamSink) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while await sink.metrics().queuedFragments != 0 {
            guard ContinuousClock.now < deadline else { throw YouTubeHLSPackagingError.shutdownTimedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test(arguments: [0.1, 3.0], [HLSStreamEndingPolicy.automatic, .manualDiagnostic])
    func queuedMediaAndStopTailUploadContinuouslyWithoutChangingPayloads(
        uploadSeconds: Double, endingPolicy: HLSStreamEndingPolicy
    ) async throws {
        let clock = SinkUploadClock()
        let transport = SerialSinkTransport(clock: clock, uploadSeconds: uploadSeconds)
        let sink = YouTubeHLSStreamSink()
        try await sink.prepare(endpoint: .manualPrimary(streamKey: "test"),
                               sessionIdentifier: "continuous_queue", userAgent: "Tubeist/Test",
                               endingPolicy: endingPolicy,
                               transport: transport, sleeper: { _ in },
                               uploadNow: { clock.now() })
        await sink.enqueue(Fragment(sequence: 0, segment: directSentinel(0), duration: 2, container: .mpegTransportStream))
        try await transport.waitUntilRequested()
        for sequence in 1...4 {
            await sink.enqueue(Fragment(sequence: sequence, segment: directSentinel(UInt8(sequence)),
                                        duration: 2, container: .mpegTransportStream))
        }
        await transport.releaseFirstRequest()
        #expect(try await sink.finish(timeout: 120) == endingPolicy.automaticallyEndsBroadcast)
        let media = await transport.media
        #expect(media.count == 5)
        #expect(media.first?.startedAt == 0)
        for index in 1..<media.count {
            let spacing = media[index].startedAt - media[index - 1].startedAt
            #expect(abs(spacing - uploadSeconds) < 0.000001)
        }
        #expect(media.map(\.body) == (0...4).map { directSentinel(UInt8($0)) })
        #expect(await transport.endListReceived == endingPolicy.automaticallyEndsBroadcast)
        #expect(await sink.metrics().droppedFragments == 0)
    }

    @Test(arguments: [false, true])
    func cancellingOrReplacingSessionInterruptsUploadWithoutUploadingOldMedia(replace: Bool) async throws {
        let clock = SinkUploadClock()
        let oldTransport = SerialSinkTransport(clock: clock, uploadSeconds: 0.1)
        let sink = YouTubeHLSStreamSink()
        try await sink.prepare(endpoint: .manualPrimary(streamKey: "test"),
                               sessionIdentifier: "old_session", userAgent: "Tubeist/Test",
                               transport: oldTransport, sleeper: { _ in },
                               uploadNow: { clock.now() })
        await sink.enqueue(Fragment(sequence: 0, segment: directSentinel(0), duration: 2, container: .mpegTransportStream))
        try await oldTransport.waitUntilRequested()
        for sequence in 1...3 {
            await sink.enqueue(Fragment(sequence: sequence, segment: directSentinel(UInt8(sequence)), duration: 2, container: .mpegTransportStream))
        }
        if !replace { await sink.cancel() }
        let newTransport = DirectSinkTransport()
        try await sink.prepare(endpoint: .manualPrimary(streamKey: "test"),
                               sessionIdentifier: "new_session", userAgent: "Tubeist/Test",
                               transport: newTransport, sleeper: { _ in })
        await sink.enqueue(Fragment(sequence: 0, segment: directSentinel(42), duration: 2, container: .mpegTransportStream))
        #expect(try await sink.finish(timeout: successfulSinkShutdownTimeout))
        #expect(await oldTransport.media.isEmpty)
        #expect(await newTransport.requests().count == 3)
        #expect(await newTransport.requests()[1].body == directSentinel(42))
    }

    @Test func shutdownDeadlineInterruptsUploadWithoutSendingAnEarlyEndList() async throws {
        let clock = SinkUploadClock()
        let transport = SerialSinkTransport(clock: clock, uploadSeconds: 0.1)
        let sink = YouTubeHLSStreamSink()
        try await sink.prepare(endpoint: .manualPrimary(streamKey: "test"),
                               sessionIdentifier: "deadline", userAgent: "Tubeist/Test", transport: transport)
        await sink.enqueue(Fragment(sequence: 0, segment: directSentinel(0), duration: 2, container: .mpegTransportStream))
        try await transport.waitUntilRequested()
        await #expect(throws: YouTubeHLSPackagingError.self) { try await sink.finish(timeout: 0.05) }
        #expect(await transport.media.isEmpty)
        #expect(await transport.endListReceived == false)
        #expect(await sink.metrics().queuedFragments == 0)
    }

    @Test func emptySessionDoesNotAuthorizeBroadcastCompletion() async throws {
        let transport = DirectSinkTransport()
        let sink = YouTubeHLSStreamSink()
        try await sink.prepare(endpoint: .manualPrimary(streamKey: "test"),
                               sessionIdentifier: "empty_session", userAgent: "Tubeist/Test",
                               transport: transport, sleeper: { _ in })
        #expect(try await sink.finish(timeout: successfulSinkShutdownTimeout) == false)
        #expect(await transport.requests().isEmpty)
    }

    @Test(arguments: [0, 3])
    func overflowDuringAnUploadMarksTheNextSegmentDiscontinuous(startupDelaySeconds: Int) async throws {
        // Exercise a slow request start as well as the normal path. CI can
        // pause the upload worker longer than the old one-second polling budget.
        let transport = RecoveringDirectSinkTransport(firstRequestDelay: .seconds(startupDelaySeconds))
        let endpoint = try YouTubeHLSEndpoint(URL(string: "https://upload.youtube.com/http_upload_hls?cid=not-a-real-key&file=")!)
        let sink = YouTubeHLSStreamSink()
        try await sink.prepare(endpoint: endpoint, sessionIdentifier: "overflow_session", userAgent: "Tubeist/Test", transport: transport, sleeper: { _ in })
        await sink.enqueue(Fragment(sequence: 0, segment: directSentinel(0), duration: 2, container: .mpegTransportStream))
        try await transport.waitUntilRequested()
        for sequence in 1...31 {
            // The queue handles opaque, already-muxed payloads; distinguish
            // these small sentinels to verify which segment survives overflow.
            await sink.enqueue(Fragment(sequence: sequence, segment: directSentinel(UInt8(sequence)), duration: 2,
                                        container: .mpegTransportStream))
        }
        await transport.releaseFirstRequest()
        #expect(try await sink.finish(timeout: successfulSinkShutdownTimeout))
        let requests = await transport.requests()
        #expect(!String(decoding: requests[0].body, as: UTF8.self).contains("#EXT-X-DISCONTINUITY\n"))
        #expect(String(decoding: requests[2].body, as: UTF8.self).contains("#EXT-X-DISCONTINUITY\n"))
        #expect(requests[3].body == (try MPEGTransportStreamMuxer.markingDiscontinuity(directSentinel(31))))
        #expect(await sink.metrics().droppedFragments == 30)
    }

    @Test(arguments: [1.0, 2.0, 5.0])
    func durationOverflowResumesAtNewestCompleteSegmentAndSelectsFloor(duration: Double) async throws {
        let clock = SinkUploadClock()
        let transport = SerialSinkTransport(clock: clock, uploadSeconds: 0.1)
        let sink = YouTubeHLSStreamSink()
        try await sink.prepare(endpoint: .manualPrimary(streamKey: "test"),
                               sessionIdentifier: "duration_overflow", userAgent: "Tubeist/Test",
                               transport: transport,
                               bitrateController: AdaptiveBitrateController(maximumBitrate: 6_000_000,
                                   minimumBitrate: 1_000_000, audioBitrate: 128_000),
                               sleeper: { _ in }, uploadNow: { clock.now() })
        await sink.enqueue(Fragment(sequence: 0, segment: directSentinel(0), duration: duration, container: .mpegTransportStream))
        try await transport.waitUntilRequested()
        for sequence in 1...15 {
            clock.transfer(duration)
            await sink.enqueue(Fragment(sequence: sequence, segment: directSentinel(UInt8(sequence)),
                                        duration: duration, container: .mpegTransportStream))
            #expect(await sink.metrics().queuedDuration <= 10 + duration)
        }
        #expect(await sink.metrics().videoBitrate == 1_000_000)
        await transport.releaseFirstRequest()
        #expect(try await sink.finish(timeout: successfulSinkShutdownTimeout))
        #expect(await transport.media.map(\.body) == [directSentinel(0),
            try MPEGTransportStreamMuxer.markingDiscontinuity(directSentinel(15))])
        #expect(await sink.metrics().droppedFragments == 14)
        #expect(await sink.metrics().lastAcceptedMediaSequence == 1)
    }

    @Test func activeUploadWatchdogReducesBitrateWithoutAnAckOrAnotherArrival() async throws {
        let clock = SinkUploadClock()
        let transport = SerialSinkTransport(clock: clock, uploadSeconds: 0.1)
        let sink = YouTubeHLSStreamSink()
        try await sink.prepare(endpoint: .manualPrimary(streamKey: "test"),
                               sessionIdentifier: "watchdog", userAgent: "Tubeist/Test", transport: transport,
                               bitrateController: AdaptiveBitrateController(maximumBitrate: 6_000_000,
                                   minimumBitrate: 1_000_000, audioBitrate: 128_000),
                               uploadNow: { clock.now() })
        await sink.enqueue(Fragment(sequence: 0, segment: Data(repeating: 0, count: 1_500_000),
                                    duration: 2, container: .mpegTransportStream))
        try await transport.waitUntilRequested()
        await sink.enqueue(Fragment(sequence: 1, segment: Data(repeating: 0, count: 1_500_000),
                                    duration: 2, container: .mpegTransportStream))
        #expect(await sink.metrics().videoBitrate == 6_000_000)
        clock.transfer(3)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        // Reading metrics does not evaluate the controller; only its watchdog can act.
        while await sink.metrics().videoBitrate == 6_000_000, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await sink.metrics().videoBitrate! < 6_000_000)
        #expect(await transport.media.isEmpty)
        await sink.cancel()
        #expect(await sink.metrics().videoBitrate == nil)
    }

    @Test func overflowCatchupPreservesNewestCompleteSegmentAndSplitStopTail() async throws {
        let transport = RecoveringDirectSinkTransport()
        let sink = YouTubeHLSStreamSink()
        try await sink.prepare(endpoint: .manualPrimary(streamKey: "test"),
                               sessionIdentifier: "overflow_stop_tail", userAgent: "Tubeist/Test",
                               transport: transport, sleeper: { _ in })
        await sink.enqueue(Fragment(sequence: 0, segment: FMP4Fixture.initialization(), duration: 0, type: .initialization))
        await sink.enqueue(Fragment(sequence: 1, segment: directSentinel(1), duration: 2, container: .mpegTransportStream))
        try await transport.waitUntilRequested()
        for sequence in 2...7 {
            await sink.enqueue(Fragment(sequence: sequence, segment: directSentinel(UInt8(sequence)),
                                        duration: 2, container: .mpegTransportStream))
        }
        await sink.enqueue(Fragment(sequence: 8, segment: FMP4Fixture.mediaSegment(includeAudio: false),
                                    duration: 0.04, type: .finalization))
        await sink.enqueue(Fragment(sequence: 9, segment: FMP4Fixture.mediaSegment(includeVideo: false),
                                    duration: 0.03, type: .finalization))
        await transport.releaseFirstRequest()
        #expect(try await sink.finish(timeout: successfulSinkShutdownTimeout))
        let media = await transport.requests().filter { $0.contentType == "video/mp2t" }
        #expect(media.count == 3)
        #expect(media[0].body == directSentinel(1))
        #expect(media[1].body == (try MPEGTransportStreamMuxer.markingDiscontinuity(directSentinel(7))))
        let tailPIDs = directSinkPacketPIDs(media.last!.body)
        #expect(tailPIDs.contains(MPEGTransportStreamMuxer.videoPID))
        #expect(tailPIDs.contains(MPEGTransportStreamMuxer.audioPID))
        #expect(await sink.metrics().droppedFragments == 5)
    }

    @Test func directlyUploadsTransportSegmentsWithoutMP4Initialization() async throws {
        let reader = ISOBMFFReader()
        let initialization = try reader.parseInitializationSegment(FMP4Fixture.initialization())
        let media = try reader.parseMediaSegment(FMP4Fixture.mediaSegment(), initialization: initialization)
        var muxer = MPEGTransportStreamMuxer()
        let ts = try muxer.mux(media, initialization: initialization)
        let transport = DirectSinkTransport()
        let endpoint = try YouTubeHLSEndpoint(URL(string: "https://upload.youtube.com/http_upload_hls?cid=not-a-real-key&file=")!)
        let sink = YouTubeHLSStreamSink()
        try await sink.prepare(endpoint: endpoint, sessionIdentifier: "vt_direct_session", userAgent: "Tubeist/Test",
                               transport: transport, bitrateController: AdaptiveBitrateController(
                                maximumBitrate: 4_000_000, minimumBitrate: 1_000_000, audioBitrate: 128_000), sleeper: { _ in })
        await sink.enqueue(Fragment(sequence: 0, segment: ts.data, duration: ts.duration, container: .mpegTransportStream))
        try await sink.finish(timeout: successfulSinkShutdownTimeout)
        let requests = await transport.requests()
        #expect(requests.count == 3)
        #expect(requests[1].contentType == "video/mp2t")
        #expect(requests[1].body == ts.data)
        #expect(String(decoding: requests[2].body, as: UTF8.self).hasSuffix("#EXT-X-ENDLIST\n"))
        let metrics = await sink.metrics()
        #expect(metrics.failure == nil)
        #expect(metrics.videoBitrate == 4_000_000)
    }

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
            transport: transport, sleeper: { _ in }
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
        try await sink.finish(timeout: successfulSinkShutdownTimeout)

        let requests = await transport.requests()
        #expect(requests.count == 3)
        #expect(requests[0].contentType == "application/vnd.apple.mpegurl")
        #expect(requests[1].contentType == "video/mp2t")
        #expect(requests[2].contentType == "application/vnd.apple.mpegurl")
        #expect(String(decoding: requests[2].body, as: UTF8.self).hasSuffix("#EXT-X-ENDLIST\n"))
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
            transport: slowTransport, sleeper: { _ in }
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
            transport: newTransport, sleeper: { _ in }
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
        try await sink.finish(timeout: successfulSinkShutdownTimeout)

        let requests = await newTransport.requests()
        #expect(requests.count == 3)
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
            transport: transport, sleeper: { _ in }
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
        try await sink.finish(timeout: successfulSinkShutdownTimeout)

        let requests = await transport.requests()
        #expect(requests.count == 3)
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
            transport: transport, sleeper: { _ in }
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

        let bufferedMetrics = await sink.metrics()
        #expect(bufferedMetrics.queuedFragments == 1)

        try await sink.finish(timeout: successfulSinkShutdownTimeout)

        let requests = await transport.requests()
        #expect(requests.count == 3)
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
            transport: transport, sleeper: { _ in }
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

        try await sink.finish(timeout: successfulSinkShutdownTimeout)

        let requests = await transport.requests()
        #expect(requests.count == 3)
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
            transport: transport, sleeper: { _ in }
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
            try await sink.finish(timeout: successfulSinkShutdownTimeout)
            Issue.record("Expected malformed media to fail shutdown")
        } catch let error as YouTubeHLSPackagingError {
            if case .packagingFailed = error {
                // Expected: the public error is accurate and contains no URL.
            } else {
                Issue.record("Unexpected shutdown error: \(error)")
            }
        }
    }

    @Test func recoveredSixtySecondNetworkStallUploadsEverySegmentInOrder() async throws {
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
        let transport = RecoveringDirectSinkTransport()
        let endpoint = try YouTubeHLSEndpoint(URL(
            string: "https://upload.youtube.com/http_upload_hls?cid=not-a-real-key&file="
        )!)
        let sink = YouTubeHLSStreamSink()
        try await sink.prepare(
            endpoint: endpoint,
            sessionIdentifier: "recovery_session",
            userAgent: "Tubeist/Test",
            transport: transport, sleeper: { _ in }
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
        for sequence in 2..<32 {
            let mediaIndex = sequence - 1
            await sink.enqueue(Fragment(
                sequence: sequence,
                segment: FMP4Fixture.mediaSegment(
                    sequence: UInt32(7 + mediaIndex),
                    videoDecodeTime: 1_000 + UInt64(mediaIndex * 3_000),
                    audioDecodeTime: 480 + UInt64(mediaIndex * 1_600)
                ),
                duration: fragmentDuration,
                type: .separable
            ))
        }

        let stalledMetrics = await sink.metrics()
        #expect(stalledMetrics.queuedFragments == 31)
        #expect(stalledMetrics.droppedFragments == 0)

        await transport.releaseFirstRequest()
        try await sink.finish(timeout: successfulSinkShutdownTimeout)

        let requests = await transport.requests()
        #expect(requests.count == 63)
        for sequence in 0..<31 {
            let playlistRequest = requests[sequence * 2]
            let segmentRequest = requests[sequence * 2 + 1]
            let playlist = String(decoding: playlistRequest.body, as: UTF8.self)
            #expect(playlistRequest.contentType == "application/vnd.apple.mpegurl")
            #expect(segmentRequest.contentType == "video/mp2t")
            #expect(playlist.contains("tb3gkQ16ELXaAeeuYq5GYFw_\(String(sequence, radix: 36)).ts"))
            #expect(!playlist.contains("#EXT-X-DISCONTINUITY\n"))
        }
        let finalPlaylist = String(decoding: requests[62].body, as: UTF8.self)
        #expect(finalPlaylist.hasSuffix("#EXT-X-ENDLIST\n"))
        #expect(!finalPlaylist.contains("#EXT-X-PLAYLIST-TYPE"))
        // The tiny fixture segments together span less than three target durations.
        #expect(finalPlaylist.contains("#EXT-X-MEDIA-SEQUENCE:0\n"))
        #expect(finalPlaylist.split(separator: "\n").filter { $0.hasSuffix(".ts") }.map(String.init)
            == (0..<31).map { "tb3gkQ16ELXaAeeuYq5GYFw_\(String($0, radix: 36)).ts" })
        let finishedMetrics = await sink.metrics()
        #expect(finishedMetrics.lastAcceptedMediaSequence == 30)
        #expect(finishedMetrics.droppedFragments == 0)
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
            transport: transport, sleeper: { _ in }
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
        // Tiny fixture fragments reach the count cap before the duration cap.
        for sequence in 2..<32 {
            await sink.enqueue(Fragment(
                sequence: sequence,
                segment: FMP4Fixture.mediaSegment(),
                duration: fragmentDuration,
                type: .separable
            ))
        }

        let oneMinuteStallMetrics = await sink.metrics()
        #expect(oneMinuteStallMetrics.queuedFragments == 31)
        #expect(oneMinuteStallMetrics.droppedFragments == 0)
        #expect(oneMinuteStallMetrics.queuedDuration <= fragmentDuration * 31 + 0.001)

        // Overflow discards the old waiting queue and preserves the active request.
        for sequence in 32..<39 {
            await sink.enqueue(Fragment(
                sequence: sequence,
                segment: FMP4Fixture.mediaSegment(),
                duration: fragmentDuration,
                type: .separable
            ))
        }

        let stalledMetrics = await sink.metrics()
        #expect(stalledMetrics.queuedFragments <= YouTubeHLSStreamSink.maximumQueuedFragments + 1)
        #expect(stalledMetrics.droppedFragments == 30)
        #expect(
            stalledMetrics.queuedDuration
                <= fragmentDuration * Double(YouTubeHLSStreamSink.maximumQueuedFragments + 1) + 0.001
        )

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

private final class SinkUploadClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = 0.0
    func now() -> Double { lock.withLock { instant } }
    func transfer(_ seconds: Double) { lock.withLock { instant += seconds } }

}

private actor SerialSinkTransport: YouTubeHLSHTTPTransport {
    struct Media: Sendable {
        let startedAt: Double
        let body: Data
    }
    let clock: SinkUploadClock
    let uploadSeconds: Double
    private let started = SinkRequestStarted()
    private var firstRequest = true
    private var gate: CheckedContinuation<Void, Error>?
    private(set) var media: [Media] = []
    private(set) var endListReceived = false
    private(set) var discontinuousPlaylists = 0

    init(clock: SinkUploadClock, uploadSeconds: Double) {
        self.clock = clock
        self.uploadSeconds = uploadSeconds
    }

    func send(_ request: URLRequest, body: Data) async throws -> YouTubeHLSHTTPResponse {
        if firstRequest {
            firstRequest = false
            try await withCheckedThrowingContinuation { continuation in
                gate = continuation
                started.signal()
            }
        }
        if request.value(forHTTPHeaderField: "Content-Type") == "video/mp2t" {
            media.append(Media(startedAt: clock.now(), body: body))
            clock.transfer(uploadSeconds)
        } else if String(decoding: body, as: UTF8.self).contains("#EXT-X-ENDLIST") {
            endListReceived = true
        }
        if request.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl",
           String(decoding: body, as: UTF8.self).contains("#EXT-X-DISCONTINUITY\n") {
            discontinuousPlaylists += 1
        }
        return YouTubeHLSHTTPResponse(statusCode: 200)
    }

    func waitUntilRequested() async throws { try await started.wait() }
    func releaseFirstRequest() { gate?.resume(); gate = nil }
    func invalidate() { gate?.resume(throwing: BlockingTransportError.invalidated); gate = nil }
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

// Each mock has one observer waiting for its first request. Buffer the signal
// in case send arrives first, and suspend the observer instead of polling the
// transport actor. The deadline still fails a worker that never starts.
private struct SinkRequestStarted: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func signal() {
        continuation.yield(())
    }

    func wait() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                _ = await iterator.next()
                try Task.checkCancellation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw BlockingTransportError.requestNeverStarted
            }
            try await group.next()
        }
    }
}

private actor SlowDirectSinkTransport: YouTubeHLSHTTPTransport {
    private let requestStarted = SinkRequestStarted()

    func send(_ request: URLRequest, body: Data) async throws -> YouTubeHLSHTTPResponse {
        requestStarted.signal()
        try await Task.sleep(for: .milliseconds(100))
        return YouTubeHLSHTTPResponse(statusCode: 200)
    }

    func invalidate() {}

    func waitUntilRequested() async throws {
        try await requestStarted.wait()
    }
}

private enum BlockingTransportError: Error {
    case invalidated
    case requestNeverStarted
}

private actor BlockingDirectSinkTransport: YouTubeHLSHTTPTransport {
    private let requestStarted = SinkRequestStarted()
    private var continuations: [CheckedContinuation<YouTubeHLSHTTPResponse, Error>] = []

    func send(_ request: URLRequest, body: Data) async throws -> YouTubeHLSHTTPResponse {
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            requestStarted.signal()
        }
    }

    func invalidate() {
        let pending = continuations
        continuations.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume(throwing: BlockingTransportError.invalidated) }
    }

    func waitUntilRequested() async throws {
        try await requestStarted.wait()
    }
}

private actor RecoveringDirectSinkTransport: YouTubeHLSHTTPTransport {
    private var sent: [DirectSinkRequest] = []
    private var firstContinuation: CheckedContinuation<YouTubeHLSHTTPResponse, Error>?
    private let requestStarted = SinkRequestStarted()
    private let firstRequestDelay: Duration

    init(firstRequestDelay: Duration = .zero) {
        self.firstRequestDelay = firstRequestDelay
    }

    func send(_ request: URLRequest, body: Data) async throws -> YouTubeHLSHTTPResponse {
        sent.append(DirectSinkRequest(
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            body: body
        ))
        guard sent.count == 1 else {
            return YouTubeHLSHTTPResponse(statusCode: 200)
        }
        try await Task.sleep(for: firstRequestDelay)
        return try await withCheckedThrowingContinuation { continuation in
            firstContinuation = continuation
            requestStarted.signal()
        }
    }

    func invalidate() {
        let continuation = firstContinuation
        firstContinuation = nil
        continuation?.resume(throwing: BlockingTransportError.invalidated)
    }

    func waitUntilRequested() async throws {
        try await requestStarted.wait()
    }

    func releaseFirstRequest() {
        let continuation = firstContinuation
        firstContinuation = nil
        continuation?.resume(returning: YouTubeHLSHTTPResponse(statusCode: 200))
    }

    func requests() -> [DirectSinkRequest] {
        sent
    }
}

private func directSentinel(_ sequence: UInt8) -> Data {
    Data([0x47, 0x41, 0x00, 0x10]) + Data(repeating: sequence, count: 184)
}
