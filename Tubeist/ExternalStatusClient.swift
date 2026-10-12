import Foundation

/// Fetches an exact, user-configured URL. No provider routes or schemas are
/// embedded in Tubeist, and remote text never enters the command channel.
struct ExternalStatusClient: Sendable {
    static let shared = ExternalStatusClient()
    let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 10
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    static func endpoint(_ value: String) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true else { return nil }
        return components.url
    }

    func fetch(from url: URL) async throws -> String {
        guard Self.endpoint(url.absoluteString) == url else { throw ExternalStatusError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (bytes, response) = try await session.bytes(for: request, delegate: ExternalStatusRedirectPolicy())
        // Stop the transfer on all exits, especially an oversized/chunked body.
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200, response.url == url,
              response.mimeType?.lowercased() == "text/plain",
              response.textEncodingName.map({ ["utf-8", "utf8"].contains($0.lowercased()) }) ?? true else {
            throw ExternalStatusError.invalidResponse
        }
        guard response.expectedContentLength <= ExternalStatusText.maximumBytes else {
            throw ExternalStatusError.tooLarge
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < ExternalStatusText.maximumBytes else { throw ExternalStatusError.tooLarge }
            data.append(byte)
        }
        return try ExternalStatusText.validate(data)
    }
}

/// A configured URL may contain a private token. Require its final endpoint
/// instead of following redirects, including HTTPS-to-HTTP downgrades.
private final class ExternalStatusRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class ExternalStatusRelay {
    struct Context: Equatable {
        let url: URL
        let sessionID: UUID
    }
    typealias Fetch = @Sendable (URL) async throws -> String

    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private var context: Context?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var nextPollAt = Date.distantPast
    private var failures = 0
    private(set) var latest: ExternalStatusSnapshot?
    private(set) var refreshFailed = false

    init(fetch: @escaping Fetch = { try await ExternalStatusClient.shared.fetch(from: $0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetch = fetch
        self.now = now
    }

    /// nil cancels polling and invalidates outstanding responses. A changed
    /// URL or stream session must never receive data from an earlier request.
    @discardableResult
    func update(context newContext: Context?) -> Task<Void, Never>? {
        if context != newContext {
            task?.cancel()
            task = nil
            generation = UUID()
            context = newContext
            latest = nil
            refreshFailed = false
            failures = 0
            nextPollAt = .distantPast
        }
        guard let context else { return nil }
        if let task { return task }
        guard now() >= nextPollAt else { return nil }
        let generation = generation
        let fetch = fetch
        task = Task { [weak self] in
            do {
                let text = try await fetch(context.url)
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                latest = try ExternalStatusSnapshot(text: text, receivedAt: now())
                refreshFailed = false
                failures = 0
                nextPollAt = now().addingTimeInterval(5)
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                // Keep a recent value briefly, but never extend its freshness
                // on failure. Avoid logging endpoint tokens or response text.
                refreshFailed = true
                failures = min(failures + 1, 4)
                nextPollAt = now().addingTimeInterval(min(30, 5 * pow(2, Double(failures - 1))))
            }
            self?.task = nil
        }
        return task
    }
}
