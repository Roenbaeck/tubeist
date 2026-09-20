//
//  YouTubeHLSUploaderTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct YouTubeHLSUploaderTests {

    @Test func manualEndingKeepsTheWindowWithoutEndListOrGrace() async throws {
        let transport = MockYouTubeHLSTransport(statuses: Array(repeating: 200, count: 14))
        let uploader = try YouTubeHLSUploader(
            endpoint: .manualPrimary(streamKey: "test"), sessionIdentifier: "manual_ending",
            userAgent: "Tubeist/Test", transport: transport, endingPolicy: .manualDiagnostic,
            sleeper: { _ in Issue.record("Manual ending must not wait for ENDLIST") }
        )
        for sequence in 0..<7 {
            _ = try await uploader.upload(segment: Data([UInt8(sequence)]), duration: sequence == 6 ? 0.3 : 2)
        }
        #expect(try await uploader.finish() == false)
        let records = await transport.recordedRequests()
        #expect(records.count == 14)
        #expect(records.last?.body == Data([6]))
        let finalPlaylist = String(decoding: records[12].body, as: UTF8.self)
        #expect(!finalPlaylist.contains("#EXT-X-PLAYLIST-TYPE"))
        #expect(!finalPlaylist.contains("#EXT-X-ENDLIST"))
        #expect(finalPlaylist.contains("#EXTINF:0.300000,"))
        for sequence in 0..<7 { #expect(finalPlaylist.contains("t6Q8VYRyVDuX7SP-1r4sjDQ_\(String(sequence, radix: 36)).ts")) }
        await #expect(throws: YouTubeHLSUploadError.stopped) {
            _ = try await uploader.upload(segment: Data([7]), duration: 2)
        }
    }

    @Test(arguments: [0, 7, 12])
    func finalPlaylistWaitsFromTheLastMediaAcknowledgement(secondsAlreadyElapsed: Int) async throws {
        let clock = HLSGraceTestClock()
        let transport = HLSGraceTestTransport(clock: clock)
        let uploader = try YouTubeHLSUploader(
            endpoint: .manualPrimary(streamKey: "test"), sessionIdentifier: "grace",
            userAgent: "Tubeist/Test", transport: transport,
            now: { clock.now() }, sleeper: { clock.advance($0) }
        )
        _ = try await uploader.upload(segment: Data([1]), duration: 2)
        clock.advance(.seconds(20))
        _ = try await uploader.upload(segment: Data([2]), duration: 2)
        let finalAcknowledgement = clock.now()
        clock.advance(.seconds(secondsAlreadyElapsed))
        #expect(try await uploader.finish())
        let endListSentAt = try #require(await transport.endListSentAt)
        #expect(finalAcknowledgement.duration(to: endListSentAt)
            == .seconds(max(10, secondsAlreadyElapsed)))
        #expect(await transport.mediaUploads == 2)
    }

    @Test(arguments: [false, true])
    func gracePeriodCanBeInterruptedWithoutSendingEndList(cancelTask: Bool) async throws {
        let transport = MockYouTubeHLSTransport(statuses: [200, 200])
        let started = GraceWaitSignal()
        let uploader = try YouTubeHLSUploader(
            endpoint: .manualPrimary(streamKey: "test"), sessionIdentifier: "cancel_grace",
            userAgent: "Tubeist/Test", transport: transport,
            sleeper: { delay in
                await started.signal()
                try await Task.sleep(for: delay)
            }
        )
        _ = try await uploader.upload(segment: Data([1]), duration: 2)
        let finishing = Task { try await uploader.finish() }
        await started.wait()
        if cancelTask { finishing.cancel() } else { await uploader.stop() }
        await #expect(throws: YouTubeHLSUploadError.stopped) { try await finishing.value }
        #expect(await transport.recordedRequests().count == 2)
    }

    @Test(arguments: [0, 7, 15])
    func completionGraceStartsAfterEndListAcknowledgement(acknowledgementDelay: Int) async throws {
        let clock = HLSGraceTestClock()
        let transport = HLSGraceTestTransport(clock: clock,
            endListAcknowledgementDelay: .seconds(acknowledgementDelay))
        let uploader = try YouTubeHLSUploader(
            endpoint: .manualPrimary(streamKey: "test"), sessionIdentifier: "completion_grace",
            userAgent: "Tubeist/Test", transport: transport,
            now: { clock.now() }, sleeper: { clock.advance($0) }
        )
        _ = try await uploader.upload(segment: Data([1]), duration: 2)
        let mediaAcknowledgedAt = clock.now()
        #expect(try await uploader.finish())
        let endListAcknowledgedAt = clock.now()
        #expect(mediaAcknowledgedAt.duration(to: endListAcknowledgedAt)
            == .seconds(10 + acknowledgementDelay))

        let deadline = try await YouTubeCompletionGrace.wait(
            deadline: clock.now().advanced(by: .seconds(140)),
            now: { clock.now() }, sleep: { clock.advance($0) }
        )
        #expect(endListAcknowledgedAt.duration(to: clock.now()) == .seconds(120))
        // Waiting must not use up the API request's own eight-second budget.
        #expect(clock.now().duration(to: deadline) == .seconds(8))
    }

    @Test(arguments: [0, 18, 119, 120])
    func completionGraceNeverShortensTheWaitToMeetADeadline(secondsRemaining: Int) async throws {
        let clock = HLSGraceTestClock()
        await #expect(throws: URLError(.timedOut)) {
            try await YouTubeCompletionGrace.wait(
                deadline: clock.now().advanced(by: .seconds(secondsRemaining)),
                now: { clock.now() },
                sleep: { _ in Issue.record("Insufficient time must leave completion to auto-stop") }
            )
        }
    }

    @Test(arguments: [122, 140])
    func completionRequestStaysWithinTheShutdownDeadline(secondsRemaining: Int) async throws {
        let clock = HLSGraceTestClock()
        let shutdownDeadline = clock.now().advanced(by: .seconds(secondsRemaining))
        let requestDeadline = try await YouTubeCompletionGrace.wait(
            deadline: shutdownDeadline, now: { clock.now() }, sleep: { clock.advance($0) }
        )
        #expect(requestDeadline == min(shutdownDeadline, clock.now().advanced(by: .seconds(8))))
    }

    @Test func completionGraceRejectsAnExpiredDeadlineAfterResuming() async throws {
        let clock = HLSGraceTestClock()
        await #expect(throws: URLError(.timedOut)) {
            try await YouTubeCompletionGrace.wait(
                deadline: clock.now().advanced(by: .seconds(140)),
                now: { clock.now() }, sleep: { _ in clock.advance(.seconds(150)) }
            )
        }
    }

    @Test func completionGraceCanBeCancelled() async throws {
        let started = GraceWaitSignal()
        let finishing = Task {
            try await YouTubeCompletionGrace.wait(deadline: .now.advanced(by: .seconds(140)),
                sleep: { delay in
                    await started.signal()
                    try await Task.sleep(for: delay)
                })
        }
        await started.wait()
        finishing.cancel()
        await #expect(throws: CancellationError.self) { try await finishing.value }
    }

    @Test func deadlineInterruptsGraceWithoutPublishingAnEarlyEndList() async throws {
        let transport = MockYouTubeHLSTransport(statuses: [200, 200])
        let uploader = try YouTubeHLSUploader(
            endpoint: .manualPrimary(streamKey: "test"), sessionIdentifier: "deadline_grace",
            userAgent: "Tubeist/Test", transport: transport
        )
        _ = try await uploader.upload(segment: Data([1]), duration: 2)
        let start = ContinuousClock.now
        await #expect(throws: YouTubeHLSUploadError.stopped) {
            try await uploader.finish(deadline: start.advanced(by: .milliseconds(30)))
        }
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(await transport.recordedRequests().count == 2)
    }

    @Test func emptySessionDoesNotWaitOrSendEndList() async throws {
        let transport = MockYouTubeHLSTransport(statuses: [])
        let uploader = try YouTubeHLSUploader(
            endpoint: .manualPrimary(streamKey: "test"), sessionIdentifier: "empty_grace",
            userAgent: "Tubeist/Test", transport: transport,
            sleeper: { _ in Issue.record("Empty session must not wait") }
        )
        #expect(try await uploader.finish() == false)
        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test func reconnectsBeyondTheRetryBudgetWithIdenticalAdvertisedBytes() async throws {
        let transport = MockYouTubeHLSTransport(statuses: [200] + Array(repeating: 503, count: 12) + [200])
        let uploader = try YouTubeHLSUploader(
            endpoint: .manualPrimary(streamKey: "test"), sessionIdentifier: "long_outage",
            userAgent: "Tubeist/Test", transport: transport, retryPolicy: testRetryPolicy,
            keepRetrying: true, sleeper: { _ in })
        let data = Data([0x47, 42])
        let receipt = try await uploader.upload(segment: data, duration: 2)
        let requests = await transport.recordedRequests()
        #expect(receipt.sequence == 0)
        #expect(requests.count == 14)
        #expect(Set(requests.dropFirst().map(\.url)).count == 1)
        #expect(requests.dropFirst().allSatisfy { $0.body == data })
        #expect(await uploader.outstandingCount == 0)
        #expect(await uploader.diagnostics.isReconnecting == false)
    }

    @Test(arguments: [408, 429])
    func retriesTemporaryClientErrors(_ status: Int) async throws {
        let transport = MockYouTubeHLSTransport(statuses: [status, 200, 200])
        let uploader = try YouTubeHLSUploader(
            endpoint: .manualPrimary(streamKey: "test"), sessionIdentifier: "temporary_error",
            userAgent: "Tubeist/Test", transport: transport, retryPolicy: testRetryPolicy, sleeper: { _ in })
        _ = try await uploader.upload(segment: Data([0x47]), duration: 2)
        #expect(await transport.recordedRequests().count == 3)
    }

    @Test func stopInterruptsPersistentRetryBackoff() async throws {
        let transport = MockYouTubeHLSTransport(statuses: Array(repeating: 503, count: 20))
        let uploader = try YouTubeHLSUploader(
            endpoint: .manualPrimary(streamKey: "test"), sessionIdentifier: "cancel_outage",
            userAgent: "Tubeist/Test", transport: transport,
            retryPolicy: .init(maximumAttempts: 1, initialDelay: 0.01, maximumDelay: 0.01, jitterFraction: 0),
            keepRetrying: true)
        let upload = Task { try await uploader.upload(segment: Data([0x47]), duration: 2) }
        await waitForRequest(on: transport)
        await uploader.stop()
        do { _ = try await upload.value; Issue.record("Expected stopped upload") }
        catch let error as YouTubeHLSUploadError { #expect(error == .stopped) }
    }

    @Test func finalPlaylistObeysShutdownDeadlineDuringAnOutage() async throws {
        let clock = HLSGraceTestClock()
        let transport = MockYouTubeHLSTransport(statuses: [200, 200] + Array(repeating: 503, count: 100))
        let uploader = try YouTubeHLSUploader(
            endpoint: .manualPrimary(streamKey: "test"), sessionIdentifier: "final_deadline",
            userAgent: "Tubeist/Test", transport: transport,
            retryPolicy: .init(maximumAttempts: 1, initialDelay: 0.01, maximumDelay: 0.01, jitterFraction: 0),
            keepRetrying: true, now: { clock.now() })
        _ = try await uploader.upload(segment: Data([0x47]), duration: 2)
        clock.advance(.seconds(10))
        let start = ContinuousClock.now
        do {
            try await uploader.finish(deadline: start.advanced(by: .milliseconds(30)))
            Issue.record("Expected the final playlist to stop at its deadline")
        } catch let error as YouTubeHLSUploadError { #expect(error == .stopped) }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(await transport.recordedRequests().count >= 3)
    }

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
        #expect(records[0].url.hasSuffix("file=tsHXlVdhmo_12NTFw52NfbA.m3u8"))
        #expect(records[1].url.hasSuffix("file=tsHXlVdhmo_12NTFw52NfbA_0.ts"))
        #expect(records[2].url.hasSuffix("file=tsHXlVdhmo_12NTFw52NfbA.m3u8"))
        #expect(records[3].url.hasSuffix("file=tsHXlVdhmo_12NTFw52NfbA_1.ts"))
        #expect(!records.map(\.url).contains { $0.contains("%2E") || $0.contains("%5F") })
        #expect(records[0].contentType == "application/vnd.apple.mpegurl")
        #expect(records[1].contentType == "video/mp2t")
        #expect(records.allSatisfy { $0.userAgent == "Apple/iPhone Tubeist/1.0" })
        #expect(records[1].body == Data([1, 2, 3]))
        #expect(records[3].body == Data([4, 5]))

        let firstPlaylist = try #require(String(data: records[0].body, encoding: .utf8))
        let secondPlaylist = try #require(String(data: records[2].body, encoding: .utf8))
        #expect(firstPlaylist.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        #expect(firstPlaylist.contains("tsHXlVdhmo_12NTFw52NfbA_0.ts"))
        #expect(!firstPlaylist.contains("tsHXlVdhmo_12NTFw52NfbA_1.ts"))
        #expect(secondPlaylist.contains("tsHXlVdhmo_12NTFw52NfbA_0.ts"))
        #expect(secondPlaylist.contains("tsHXlVdhmo_12NTFw52NfbA_1.ts"))
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
        #expect(records[3].url.hasSuffix("t77cOpd9W37mxhCXpUoy_eA_0.ts"))
        let diagnostics = await uploader.diagnostics
        #expect(diagnostics.retryCount == 2)
        #expect(diagnostics.lastHTTPStatus == 200)
    }

    @Test func finishPublishesAnEndListAfterTheLastAcknowledgedSegment() async throws {
        let transport = MockYouTubeHLSTransport(statuses: [200, 200, 200])
        let endpoint = try YouTubeHLSEndpoint(URL(
            string: "https://upload.youtube.com/http_upload_hls?cid=redacted&file="
        )!)
        let uploader = try YouTubeHLSUploader(
            endpoint: endpoint,
            sessionIdentifier: "final_session",
            userAgent: "Tubeist/Test",
            transport: transport,
            retryPolicy: testRetryPolicy,
            sleeper: { _ in }
        )

        _ = try await uploader.upload(segment: Data([0x47]), duration: 1.75)
        try await uploader.finish()

        let records = await transport.recordedRequests()
        #expect(records.count == 3)
        #expect(records[0].url.hasSuffix("file=tOadCzDfEoC_aihm9C8HTFw.m3u8"))
        #expect(records[1].url.hasSuffix("file=tOadCzDfEoC_aihm9C8HTFw_0.ts"))
        #expect(records[2].url.hasSuffix("file=tOadCzDfEoC_aihm9C8HTFw.m3u8"))
        let finalPlaylist = try #require(String(data: records[2].body, encoding: .utf8))
        #expect(finalPlaylist.contains("tOadCzDfEoC_aihm9C8HTFw_0.ts"))
        #expect(finalPlaylist.contains("#EXTINF:1.750000,"))
        #expect(finalPlaylist.hasSuffix("#EXT-X-ENDLIST\n"))
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

    @Test func retainsTheRollingWindowThroughShutdown() async throws {
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
        for (sequence, playlist) in playlists.enumerated() {
            let firstRetained = max(0, sequence - 14)
            #expect(!playlist.contains("#EXT-X-PLAYLIST-TYPE"))
            #expect(playlist.contains("#EXT-X-MEDIA-SEQUENCE:\(firstRetained)\n"))
            #expect(playlist.split(separator: "\n").filter { $0.hasSuffix(".ts") }.map(String.init)
                == (firstRetained...sequence).map { "tJx0g9E94V9LWBSp56-3AKA_\(String($0, radix: 36)).ts" })
        }
        let lastPlaylist = try #require(playlists.last)
        #expect(await uploader.outstandingCount == 0)
        #expect(await uploader.queuedDuration == 0)

        try await uploader.finish()
        let finalRequests = await transport.recordedRequests()
        #expect(finalRequests.count == 101)
        let finalPlaylist = String(decoding: try #require(finalRequests.last).body, as: UTF8.self)
        #expect(finalPlaylist == lastPlaylist + "#EXT-X-ENDLIST\n")
    }
}

private final class HLSGraceTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    func now() -> ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}

private actor HLSGraceTestTransport: YouTubeHLSHTTPTransport {
    let clock: HLSGraceTestClock
    let endListAcknowledgementDelay: Duration
    private(set) var endListSentAt: ContinuousClock.Instant?
    private(set) var mediaUploads = 0

    init(clock: HLSGraceTestClock, endListAcknowledgementDelay: Duration = .zero) {
        self.clock = clock
        self.endListAcknowledgementDelay = endListAcknowledgementDelay
    }

    func send(_ request: URLRequest, body: Data) async throws -> YouTubeHLSHTTPResponse {
        if request.value(forHTTPHeaderField: "Content-Type") == "video/mp2t" {
            mediaUploads += 1
            // Upload/acknowledgement time must not consume any of the grace.
            clock.advance(.seconds(15))
        } else if String(decoding: body, as: UTF8.self).contains("#EXT-X-ENDLIST") {
            endListSentAt = clock.now()
            clock.advance(endListAcknowledgementDelay)
        }
        return YouTubeHLSHTTPResponse(statusCode: 200)
    }
    func invalidate() {}
}

private actor GraceWaitSignal {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() { started = true; waiter?.resume(); waiter = nil }
    func wait() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
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
