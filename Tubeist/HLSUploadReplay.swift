#if DEBUG
import SwiftUI
import CryptoKit

/// Explicit development launch only. Never opens capture devices, signs in,
/// changes Settings, or creates/completes a YouTube broadcast.
actor HLSUploadReplay {
    nonisolated static var isRequested: Bool { CommandLine.arguments.contains("-hls-upload-replay") }

    struct Plan: Codable, Sendable {
        struct Segment: Codable, Sendable {
            let filename: String
            let sha256: String
            let duration: Double
            let availableAt: Double
        }
        let broadcastID: String
        let segments: [Segment]

        func validate() throws {
            guard broadcastID.count == 11, broadcastID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  !segments.isEmpty, segments.count <= 300 else { throw Failure.invalidPlan }
            var previous = 0.0
            for segment in segments {
                guard segment.sha256.count == 64,
                      segment.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      segment.filename == segment.sha256 + ".ts",
                      segment.duration.isFinite, segment.duration > 0, segment.duration <= 5,
                      segment.availableAt.isFinite, segment.availableAt >= previous,
                      segment.availableAt <= 600 else { throw Failure.invalidPlan }
                previous = segment.availableAt
            }
        }
    }

    enum Failure: Error { case invalidPlan, invalidBody, emptyFinish }

    func run(progress: @Sendable @escaping (String) async -> Void) async {
        let root = URL.documentsDirectory.appendingPathComponent("HLSReplay")
        let endpointFile = root.appendingPathComponent("endpoint.txt")
        var uploader: YouTubeHLSUploader?
        var capture: HLSRequestCapture?
        var journal: ReplayHTTPJournal?
        do {
            let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: root.appendingPathComponent("plan.json")))
            try plan.validate()
            var totalBytes = 0
            // Validate all media before any upload. Read one segment at a time.
            for segment in plan.segments {
                let body = try Data(contentsOf: root.appendingPathComponent(segment.filename))
                totalBytes += body.count
                guard !body.isEmpty, body.count % 188 == 0, totalBytes <= 512 * 1024 * 1024,
                      SHA256.hash(data: body).map({ String(format: "%02x", $0) }).joined() == segment.sha256 else {
                    throw Failure.invalidBody
                }
            }
            let endpoint = try YouTubeHLSEndpoint(URL(string: String(contentsOf: endpointFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? URL(fileURLWithPath: "/invalid"))
            // Consume the explicit one-shot authorization file: relaunch cannot
            // accidentally rebroadcast this test. Never store it in Settings.
            try FileManager.default.removeItem(at: endpointFile)
            let session = HLSMediaPlaylist.makeSessionIdentifier()
            let output = root.appendingPathComponent("results_" + session)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let log = try ReplayHTTPJournal(directory: output)
            journal = log
            log.event(["kind": "prepared", "broadcastID": plan.broadcastID,
                       "segments": plan.segments.count, "mediaBytes": totalBytes,
                       "sessionIdentifier": session])
            let recorder = HLSRequestCapture(directory: output)
            capture = recorder
            await recorder.start()
            // Same URLSession configuration and uploader as production. The
            // delegate only observes metrics; it does not alter authentication.
            let transport = URLSessionYouTubeHLSHTTPTransport(requestTimeout: 10, resourceTimeout: 30, delegate: log)
            let userAgent = await MainActor.run {
                "Apple / \(UIDevice.current.model.replacingOccurrences(of: " ", with: "_")) / Tubeist-\(Bundle.main.appVersion ?? "unknown")"
            }
            let liveUploader = try YouTubeHLSUploader(endpoint: endpoint, sessionIdentifier: session, userAgent: userAgent,
                transport: HLSCapturingHTTPTransport(underlying: transport, capture: recorder))
            uploader = liveUploader
            let start = ContinuousClock.now
            for (index, segment) in plan.segments.enumerated() {
                try Task.checkCancellation()
                try await Task.sleep(until: start.advanced(by: .seconds(segment.availableAt)), clock: .continuous)
                let body = try Data(contentsOf: root.appendingPathComponent(segment.filename))
                let receipt = try await liveUploader.upload(segment: body, duration: segment.duration)
                log.event(["kind": "segmentAccepted", "sequence": receipt.sequence, "duration": segment.duration])
                await progress("Uploaded \(index + 1) of \(plan.segments.count) segments")
            }
            await progress("All segments uploaded. Waiting for the ten-second ending grace period…")
            guard try await liveUploader.finish() else { throw Failure.emptyFinish }
            await liveUploader.stop()
            log.event(["kind": "finished", "success": true])
            await progress("Replay finished. ENDLIST acknowledged.\nThe broadcast can now be ended in YouTube Studio.")
            print("HLS replay finished: \(output.lastPathComponent)")
        } catch {
            if let uploader { await uploader.stop() }
            await capture?.finish()
            try? FileManager.default.removeItem(at: endpointFile)
            // Generic type/code only: URLSession errors can contain the key URL.
            let error = error as NSError
            journal?.event(["kind": "finished", "success": false, "errorDomain": error.domain, "errorCode": error.code])
            await progress("Replay stopped (\(error.domain), code \(error.code)). See its diagnostic report.")
            print("HLS replay stopped: \(error.domain) \(error.code)")
        }
    }
}

/// Records safe timing/connection fields only; never URLs, headers or bodies.
private final class ReplayHTTPJournal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let file: FileHandle
    private let lock = NSLock()
    private let startedAt = Date()

    init(directory: URL) throws {
        let url = directory.appendingPathComponent("network.jsonl")
        try Data().write(to: url)
        file = try FileHandle(forWritingTo: url)
    }

    deinit { try? file.close() }

    func event(_ fields: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        var fields = fields
        fields["elapsed"] = Date().timeIntervalSince(startedAt)
        guard var data = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys) else { return }
        data.append(0x0a)
        try? file.write(contentsOf: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let transactions: [[String: Any]] = metrics.transactionMetrics.map { item in
            var row: [String: Any] = ["protocol": item.networkProtocolName ?? "unknown",
                                     "reusedConnection": item.isReusedConnection,
                                     "proxyConnection": item.isProxyConnection,
                                     "requestBodyBytes": item.countOfRequestBodyBytesSent,
                                     "httpStatus": (item.response as? HTTPURLResponse)?.statusCode ?? 0]
            for (name, date) in [("fetchStart", item.fetchStartDate), ("requestStart", item.requestStartDate),
                                 ("requestEnd", item.requestEndDate), ("responseStart", item.responseStartDate),
                                 ("responseEnd", item.responseEndDate)] {
                if let date { row[name] = date.timeIntervalSince(startedAt) }
            }
            return row
        }
        event(["kind": "httpMetrics", "taskID": task.taskIdentifier,
               "redirectCount": metrics.redirectCount, "transactions": transactions])
    }
}

struct HLSUploadReplayView: View {
    @State private var status = "Validating the recorded HLS test…"
    @State private var started = false

    var body: some View {
        VStack(spacing: 20) {
            Text("HLS upload replay").font(.title)
            Text(status).multilineTextAlignment(.center)
            Text("Diagnostic mode • Camera and microphone are off").foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .preferredColorScheme(.dark)
        .task {
            guard !started else { return }
            started = true
            await HLSUploadReplay().run { message in
                await MainActor.run { status = message }
            }
        }
    }
}
#endif
