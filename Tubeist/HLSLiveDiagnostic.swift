#if DEBUG
import Foundation

/// One explicitly launched, bounded live test using the normal capture pipeline.
/// Its destination is consumed from a file, never written to the user's Settings.
actor HLSLiveDiagnostic {
    static let shared = HLSLiveDiagnostic()
    nonisolated static var isRequested: Bool {
        CommandLine.arguments.contains("-hls-live-diagnostic")
    }

    struct Plan: Codable, Sendable {
        let broadcastID: String
        let duration: Double

        func validate() throws {
            guard broadcastID.count == 11,
                  broadcastID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  duration.isFinite, (10...180).contains(duration) else { throw Failure.invalidPlan }
        }
    }

    enum Failure: Error { case invalidPlan, missingDestination, missingDiagnostics, interrupted }
    private var started = false
    private var endpoint: YouTubeHLSEndpoint?
    private var task: Task<Void, Never>?
    private let root = URL.documentsDirectory.appendingPathComponent("HLSLiveTest")

    func startIfRequested() {
        guard Self.isRequested, !started else { return }
        started = true
        task = Task { await run() }
    }

    func takeEndpoint() throws -> YouTubeHLSEndpoint {
        guard Self.isRequested, let endpoint else { throw Failure.missingDestination }
        self.endpoint = nil
        return endpoint
    }

    private func run() async {
        let endpointFile = root.appendingPathComponent("endpoint.txt")
        var streamStarted = false
        var result: [String: Any] = [:]
        do {
            let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: root.appendingPathComponent("plan.json")))
            try plan.validate()
            // Supply these through UserDefaults' volatile launch argument domain.
            // Do not persist a different recording/streaming configuration.
            guard Settings.stream, Settings.record, Settings.recordHLSAcceptance else {
                throw Failure.missingDiagnostics
            }
            let destination = try String(contentsOf: endpointFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: destination) else { throw Failure.missingDestination }
            endpoint = try YouTubeHLSEndpoint(url)
            try FileManager.default.removeItem(at: endpointFile)
            let session = Streamer.makeStreamID()
            result = ["broadcastID": plan.broadcastID, "sessionIdentifier": session,
                      "requestedDuration": plan.duration, "startedAt": Date().timeIntervalSince1970]
            writeResult(result.merging(["phase": "starting"]) { _, new in new })
            print("HLS live diagnostic starting: \(session); \(Int(plan.duration)) seconds")
            try await Streamer.shared.startStream(streamID: session)
            streamStarted = true
            writeResult(result.merging(["phase": "live"]) { _, new in new })
            try await Task.sleep(for: .seconds(plan.duration))
            guard await Streamer.shared.sessionState() == .live else { throw Failure.interrupted }
            writeResult(result.merging(["phase": "stopping"]) { _, new in new })
            let stopped = try await Streamer.shared.endStream(resumePreviewAfterStop: false)
            streamStarted = false
            result["success"] = stopped.succeeded
            result["phase"] = "finished"
            print("HLS live diagnostic finished: \(session); success=\(stopped.succeeded)")
        } catch {
            if streamStarted { _ = try? await Streamer.shared.endStream(resumePreviewAfterStop: false) }
            let error = error as NSError
            result["success"] = false
            result["phase"] = "failed"
            result["errorDomain"] = error.domain
            result["errorCode"] = error.code
            print("HLS live diagnostic failed: \(error.domain) \(error.code)")
        }
        endpoint = nil
        try? FileManager.default.removeItem(at: endpointFile)
        result["finishedAt"] = Date().timeIntervalSince1970
        writeResult(result)
        task = nil
    }

    private func writeResult(_ result: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: root.appendingPathComponent("result.json"), options: .atomic)
    }
}
#endif
