#if DEBUG
import Foundation
import CryptoKit

/// Disk work stays on a utility queue. The uploader awaits each write, so a
/// slow disk cannot create an unbounded queue retaining compressed media.
final class HLSRequestCapture: @unchecked Sendable {
    private let directory: URL
    private let maximumBytes: Int
    private let maximumRequests: Int
    private let queue = DispatchQueue(label: "Tubeist.HLSRequestCapture", qos: .utility)
    // Accessed only on queue.
    private var journal: FileHandle?
    private var bodies = Set<String>()
    private var savedBytes = 0
    private var requestCount = 0
    private var pendingResponses = Set<Int>()
    private var incomplete = false
    private var finished = false
    private let startedAt = ContinuousClock.now

    init(directory: URL, maximumBytes: Int = 512 * 1024 * 1024, maximumRequests: Int = 10_000) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.maximumRequests = maximumRequests
    }

    func start() async {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    try FileManager.default.createDirectory(at: self.directory.appendingPathComponent("bodies"),
                                                           withIntermediateDirectories: true)
                    let url = self.directory.appendingPathComponent("uploads.jsonl")
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    self.journal = try FileHandle(forWritingTo: url)
                    try self.append(["kind": "captureStarted", "schema": 1, "maximumBytes": self.maximumBytes])
                } catch { self.markIncomplete("storageError") }
                continuation.resume()
            }
        }
    }

    func request(filename: String, contentType: String, body: Data) async -> Int? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !self.finished, !self.incomplete, self.journal != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    guard filename.hasPrefix("tubeist_"),
                          filename.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                              || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }),
                          (filename.hasSuffix(".ts") && contentType == "video/mp2t")
                            || (filename.hasSuffix(".m3u8") && contentType == "application/vnd.apple.mpegurl") else {
                        self.markIncomplete("unexpectedRequest")
                        continuation.resume(returning: nil)
                        return
                    }
                    guard self.requestCount < self.maximumRequests else {
                        self.markIncomplete("requestLimit")
                        continuation.resume(returning: nil)
                        return
                    }
                    let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
                    let bodyName = digest + (filename.hasSuffix(".ts") ? ".ts" : ".m3u8")
                    if !self.bodies.contains(bodyName) {
                        guard body.count <= self.maximumBytes - self.savedBytes else {
                            self.markIncomplete("byteLimit")
                            continuation.resume(returning: nil)
                            return
                        }
                        try body.write(to: self.directory.appendingPathComponent("bodies").appendingPathComponent(bodyName),
                                       options: .atomic)
                        self.bodies.insert(bodyName)
                        self.savedBytes += body.count
                    }
                    let id = self.requestCount
                    try self.append(["kind": "request", "id": id, "filename": filename,
                                     "contentType": contentType, "byteCount": body.count, "sha256": digest,
                                     "body": bodyName])
                    self.requestCount += 1
                    self.pendingResponses.insert(id)
                    continuation.resume(returning: id)
                } catch {
                    self.markIncomplete("storageError")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func response(id: Int, httpStatus: Int?) async {
        await withCheckedContinuation { continuation in
            queue.async {
                if !self.finished, self.journal != nil {
                    do {
                        try self.append(["kind": "response", "id": id,
                                         "httpStatus": httpStatus.map { $0 as Any } ?? NSNull()])
                        self.pendingResponses.remove(id)
                    } catch { self.markIncomplete("storageError") }
                }
                continuation.resume()
            }
        }
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !self.finished else { continuation.resume(); return }
                if !self.pendingResponses.isEmpty { self.markIncomplete("pendingRequests") }
                self.finished = true
                do {
                    try self.append(["kind": "captureFinished", "complete": !self.incomplete,
                                     "requests": self.requestCount, "savedBytes": self.savedBytes])
                    try self.journal?.synchronize()
                    try self.journal?.close()
                } catch { self.markIncomplete("storageError") }
                self.journal = nil
                continuation.resume()
            }
        }
    }

    private func append(_ fields: [String: Any]) throws {
        guard let journal else { throw CocoaError(.fileWriteUnknown) }
        var fields = fields
        fields["timestamp"] = ISO8601DateFormatter().string(from: Date())
        let elapsed = startedAt.duration(to: .now).components
        fields["elapsed"] = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        var data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        data.append(0x0a)
        try journal.write(contentsOf: data)
    }

    private func markIncomplete(_ reason: String) {
        guard !incomplete else { return }
        incomplete = true
        try? append(["kind": "captureIncomplete", "reason": reason])
        LOG("YouTube HLS diagnostic capture is incomplete (\(reason)); streaming continues", level: .warning)
    }
}

/// Observes the exact Data passed to the HTTP transport, including retries and
/// the final ENDLIST. Never records endpoint URLs, headers, response bodies, or
/// error descriptions, which could contain credentials.
struct HLSCapturingHTTPTransport: YouTubeHLSHTTPTransport {
    let underlying: any YouTubeHLSHTTPTransport
    let capture: HLSRequestCapture

    func send(_ request: URLRequest, body: Data) async throws -> YouTubeHLSHTTPResponse {
        let filename = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.last(where: { $0.name == "file" })?.value ?? ""
        let id = await capture.request(filename: filename,
                                       contentType: request.value(forHTTPHeaderField: "Content-Type") ?? "", body: body)
        do {
            let result = try await underlying.send(request, body: body)
            if let id { await capture.response(id: id, httpStatus: result.statusCode) }
            return result
        } catch {
            if let id { await capture.response(id: id, httpStatus: nil) }
            throw error
        }
    }

    func invalidate() async {
        await underlying.invalidate()
        await capture.finish()
    }
}
#endif
