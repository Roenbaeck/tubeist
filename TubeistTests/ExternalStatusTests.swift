import Foundation
import Testing
@testable import Tubeist

struct ExternalStatusTests {
    @Test func acceptsPlainTextAndPreservesUnicodeWithoutInterpretingMarkup() throws {
        let text = "**bold** <script>alert(1)</script> 👩‍👩‍👧‍👦 العربية"
        #expect(try ExternalStatusText.validate(Data(text.utf8)) == text)
        #expect(try ExternalStatusText.validate(Data(" a\r\nb\tc\r\nd ".utf8)) == "a\nb c\nd")
    }

    @Test func rejectsInvalidEncodingControlsAndOversizedResponses() {
        for data in [Data([0xff]), Data("\n ".utf8), Data("hello\0world".utf8),
                     Data("left\u{202e}right".utf8), Data(repeating: 65, count: 501),
                     Data(String(repeating: "a\n", count: 9).utf8),
                     Data(("a" + String(repeating: "\u{0301}", count: 2500)).utf8)] {
            #expect(throws: ExternalStatusError.self) { try ExternalStatusText.validate(data) }
        }
    }

    @Test func snapshotRevalidatesDecodedTextAndExpiresWithoutUpdates() throws {
        let now = Date()
        let snapshot = try ExternalStatusSnapshot(text: "Status", receivedAt: now)
        #expect(snapshot.isFresh(at: now.addingTimeInterval(29)))
        #expect(!snapshot.isFresh(at: now.addingTimeInterval(30)))
        #expect(!snapshot.isFresh(at: now.addingTimeInterval(-6)))
        let invalid = try PropertyListSerialization.data(fromPropertyList: [
            "text": String(repeating: "x", count: 501), "receivedAt": now,
        ], format: .binary, options: 0)
        #expect(throws: ExternalStatusError.self) {
            try PropertyListDecoder().decode(ExternalStatusSnapshot.self, from: invalid)
        }
    }

    @Test func endpointRequiresCompleteHTTPSAndKeepsPathAndQuery() {
        let url = "https://example.com/custom/display?token=abc"
        #expect(ExternalStatusClient.endpoint(" \(url)\n")?.absoluteString == url)
        for invalid in ["", "example.com", "http://example.com/status", "file:///tmp/text",
                        "https:///", "https://user:password@example.com/", "https://example.com/#fragment",
                        "https://example.com:65536/status"] {
            #expect(ExternalStatusClient.endpoint(invalid) == nil)
        }
    }

    @Test func httpClientChecksContractAndBoundsBodyEvenWithoutContentLength() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatusURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = ExternalStatusClient(session: session)
        let text = try await client.fetch(from: URL(string: "https://example.com/exact/path?token=abc")!)
        #expect(text == "plain **text**")
        for path in ["error", "redirect", "html", "latin1", "invalidUTF8", "large", "largeHeader", "empty"] {
            await #expect(throws: ExternalStatusError.self) {
                try await client.fetch(from: URL(string: "https://example.com/\(path)")!)
            }
        }
    }

    @Test func watchHealthIncludesUploadFailuresAndExpires() {
        let now = Date()
        var snapshot = WatchStateSnapshot(generatedAt: now, phase: .streaming, health: .good,
                                          healthTracked: true, healthValidUntil: now.addingTimeInterval(20), link: .good)
        #expect(snapshot.healthIndicator(at: now) == .healthy)
        snapshot.link = .failed
        #expect(snapshot.healthIndicator(at: now) == .problem)
        snapshot.link = .degraded
        #expect(snapshot.healthIndicator(at: now) == .warning)
        snapshot.link = .good
        #expect(snapshot.healthIndicator(at: now.addingTimeInterval(21)) == .unknown)
        snapshot.healthValidUntil = now.addingTimeInterval(120)
        #expect(snapshot.healthIndicator(at: now.addingTimeInterval(91)) == .unknown)
    }
}

private final class StatusURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let path = url.lastPathComponent
        var headers = ["Content-Type": "text/plain; charset=utf-8"]
        var code = 200
        var body = Data("plain **text**".utf8)
        switch path {
        case "error": code = 503
        case "redirect": code = 302; headers["Location"] = "http://other.example/"
        case "html": headers["Content-Type"] = "text/html"
        case "latin1": headers["Content-Type"] = "text/plain; charset=iso-8859-1"
        case "invalidUTF8": body = Data([0xff])
        case "large": body = Data(repeating: 65, count: 4097)
        case "largeHeader": headers["Content-Length"] = "999999"
        case "empty": body = Data()
        default:
            // The client must preserve the endpoint and negotiate plain text.
            if url.path != "/exact/path" || url.query != "token=abc"
                || request.value(forHTTPHeaderField: "Accept") != "text/plain; charset=utf-8" {
                code = 400
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code,
                                  httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
struct ExternalStatusRelayTests {
    @Test func ignoresLateResponsesAfterDisablingOrChangingSession() async throws {
        let gate = FetchGate()
        let relay = ExternalStatusRelay(fetch: { try await gate.fetch($0) })
        let url = URL(string: "https://example.com/status")!
        let firstContext = ExternalStatusRelay.Context(url: url, sessionID: UUID())
        let oldTask = try #require(relay.update(context: firstContext))
        await gate.waitForRequest()
        relay.update(context: nil)
        await gate.complete("old text")
        await oldTask.value
        #expect(relay.latest == nil)
        let replacement = ExternalStatusRelay.Context(url: url, sessionID: UUID())
        let newTask = try #require(relay.update(context: replacement))
        await gate.waitForRequest()
        await gate.complete("new text")
        await newTask.value
        #expect(relay.latest?.text == "new text")
        let changedTask = relay.update(context: .init(url: URL(string: "https://example.com/changed")!, sessionID: replacement.sessionID))
        #expect(relay.latest == nil)
        await gate.waitForRequest()
        relay.update(context: nil)
        await gate.complete("changed but disabled")
        await changedTask?.value
        #expect(relay.latest == nil)
    }

    @Test func pollsAtMostEveryFiveSecondsAndDoesNotExtendFreshnessOnFailure() async throws {
        let clock = StatusTestClock()
        let fetcher = ImmediateFetcher()
        let relay = ExternalStatusRelay(fetch: { _ in try await fetcher.fetch() }, now: { clock.now })
        let context = ExternalStatusRelay.Context(url: URL(string: "https://example.com/status")!, sessionID: UUID())
        await relay.update(context: context)?.value
        let original = try #require(relay.latest)
        #expect(relay.update(context: context) == nil)
        clock.advance(5)
        await fetcher.fail()
        await relay.update(context: context)?.value
        #expect(relay.refreshFailed)
        #expect(relay.latest == original)
        clock.advance(5)
        await relay.update(context: context)?.value
        clock.advance(5)
        #expect(relay.update(context: context) == nil) // Failure backoff is now 10 seconds.
        clock.advance(20)
        #expect(!original.isFresh(at: clock.now))
        relay.update(context: nil)
        #expect(relay.latest == nil)
        #expect(!relay.refreshFailed)
    }
}

private actor FetchGate {
    var pending: CheckedContinuation<String, any Error>?
    var waiting: CheckedContinuation<Void, Never>?
    func fetch(_ url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            waiting?.resume()
            waiting = nil
        }
    }
    func waitForRequest() async {
        if pending != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func complete(_ text: String) { pending?.resume(returning: text); pending = nil }
}

private actor ImmediateFetcher {
    var shouldFail = false
    func fail() { shouldFail = true }
    func fetch() throws -> String {
        if shouldFail { throw ExternalStatusError.invalidResponse }
        return "Current text"
    }
}

private final class StatusTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
