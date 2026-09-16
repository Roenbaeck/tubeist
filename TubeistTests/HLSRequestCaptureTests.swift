#if DEBUG
import Foundation
import Testing
@testable import Tubeist

struct HLSRequestCaptureTests {
    @Test func capturesExactRetriesAndFinalPlaylistWithoutCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = HLSRequestCapture(directory: directory)
        await capture.start()
        let transport = CaptureTestTransport(statuses: [200, 500, 200, 200, 200, 200])
        let uploader = try YouTubeHLSUploader(
            endpoint: .manualPrimary(streamKey: "private-canary-key"), sessionIdentifier: "capture_test",
            userAgent: "private-canary-header", transport: HLSCapturingHTTPTransport(underlying: transport, capture: capture),
            retryPolicy: .init(maximumAttempts: 3, initialDelay: 0, maximumDelay: 0, jitterFraction: 0),
            sleeper: { _ in }
        )
        _ = try await uploader.upload(segment: Data([0x47, 1, 2]), duration: 2)
        _ = try await uploader.upload(segment: Data([0x47, 3, 4]), duration: 0.9)
        try await uploader.finish()
        let events = try readEvents(directory)
        let requests = events.filter { $0["kind"] as? String == "request" }
        let sent = await transport.bodies
        #expect(requests.count == 6)
        #expect(sent.count == requests.count)
        for (index, request) in requests.enumerated() {
            let filename = try #require(request["body"] as? String)
            let data = try Data(contentsOf: directory.appendingPathComponent("bodies").appendingPathComponent(filename))
            #expect(data == sent[index])
            #expect(request["id"] as? Int == index)
        }
        #expect(requests[1]["body"] as? String == requests[2]["body"] as? String)
        #expect(String(decoding: try #require(sent.last), as: UTF8.self).hasSuffix("#EXT-X-ENDLIST\n"))
        #expect(events.last?["complete"] as? Bool == true)
        #expect(events.filter { $0["kind"] as? String == "response" }.count == 6)
        let journal = try String(contentsOf: directory.appendingPathComponent("uploads.jsonl"), encoding: .utf8)
        #expect(!journal.contains("private-canary"))
        #expect(!journal.contains("upload.youtube.com"))
    }

    @Test func byteLimitMarksEvidenceIncompleteButStillSendsTheOriginalBody() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = HLSRequestCapture(directory: directory, maximumBytes: 3)
        await capture.start()
        let transport = CaptureTestTransport(statuses: [200])
        let wrapper = HLSCapturingHTTPTransport(underlying: transport, capture: capture)
        var request = URLRequest(url: URL(string: "https://a.upload.youtube.com/http_upload_hls?cid=secret&file=tubeist_test_0.ts")!)
        request.setValue("video/mp2t", forHTTPHeaderField: "Content-Type")
        let body = Data([0x47, 1, 2, 3])
        #expect(try await wrapper.send(request, body: body).statusCode == 200)
        await wrapper.invalidate()
        #expect(await transport.bodies == [body])
        let events = try readEvents(directory)
        #expect(events.last?["complete"] as? Bool == false)
        #expect(events.contains { $0["reason"] as? String == "byteLimit" })
        #expect(events.last?["savedBytes"] as? Int == 0)
    }

    @Test func missingResponseCannotBeReportedAsComplete() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = HLSRequestCapture(directory: directory)
        await capture.start()
        _ = await capture.request(filename: "tubeist_test_0.ts", contentType: "video/mp2t", body: Data([0x47]))
        await capture.finish()
        #expect(try readEvents(directory).last?["complete"] as? Bool == false)
    }

    @Test func disabledDiagnosticsCreatesNoDirectory() async throws {
        let recorder = HLSAcceptanceRecorder()
        #expect(await recorder.begin(sessionIdentifier: UUID().uuidString, enabled: false) == nil)
    }

    private func readEvents(_ directory: URL) throws -> [[String: Any]] {
        let contents = try String(contentsOf: directory.appendingPathComponent("uploads.jsonl"), encoding: .utf8)
        return try contents.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
}

private actor CaptureTestTransport: YouTubeHLSHTTPTransport {
    var bodies: [Data] = []
    private var statuses: [Int]
    init(statuses: [Int]) { self.statuses = statuses }
    func send(_ request: URLRequest, body: Data) -> YouTubeHLSHTTPResponse {
        bodies.append(body)
        return YouTubeHLSHTTPResponse(statusCode: statuses.removeFirst())
    }
    func invalidate() {}
}
#endif
