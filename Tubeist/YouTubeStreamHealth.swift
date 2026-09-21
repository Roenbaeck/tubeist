import Foundation
import Observation

/// Frozen for this streaming session, independently of the Settings selection.
struct YouTubeHealthTarget: Equatable, Sendable {
    let sessionID = UUID()
    let streamID: String
    let broadcastID: String
    let authorizationScope: String
}

struct YouTubeIngestStatus: Decodable, Equatable, Sendable {
    struct Issue: Decodable, Equatable, Sendable {
        let type: String?
        let severity: String?
        let reason: String?
        let description: String?

        var diagnostic: String {
            [type, severity, reason, description].compactMap { $0 }.joined(separator: "; ")
        }
    }

    struct Health: Decodable, Equatable, Sendable {
        let status: String?
        let lastUpdateTimeSeconds: Double?
        let configurationIssues: [Issue]?

        enum CodingKeys: String, CodingKey { case status, lastUpdateTimeSeconds, configurationIssues }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            status = try values.decodeIfPresent(String.self, forKey: .status)
            configurationIssues = try values.decodeIfPresent([Issue].self, forKey: .configurationIssues)
            // Google APIs may encode uint64 values as JSON strings.
            if let number = try? values.decode(Double.self, forKey: .lastUpdateTimeSeconds) {
                lastUpdateTimeSeconds = number
            } else {
                lastUpdateTimeSeconds = (try? values.decode(String.self, forKey: .lastUpdateTimeSeconds))
                    .flatMap(Double.init)
            }
        }
    }

    let streamStatus: String?
    let healthStatus: Health?

    func sanitized(secrets: [String]) -> Self {
        // Sanitize server-provided text before it reaches logs or the UI.
        func clean(_ value: String?) -> String? { value.map { YouTubeDiagnostics.text($0, secrets: secrets) } }
        return Self(streamStatus: clean(streamStatus), healthStatus: healthStatus.map {
            Health(status: clean($0.status), lastUpdateTimeSeconds: $0.lastUpdateTimeSeconds,
                   configurationIssues: $0.configurationIssues?.map {
                Issue(type: clean($0.type), severity: clean($0.severity), reason: clean($0.reason), description: clean($0.description))
            })
        })
    }
}

extension YouTubeIngestStatus.Health {
    init(status: String?, lastUpdateTimeSeconds: Double?, configurationIssues: [YouTubeIngestStatus.Issue]?) {
        self.status = status
        self.lastUpdateTimeSeconds = lastUpdateTimeSeconds
        self.configurationIssues = configurationIssues
    }
}

struct YouTubeHealthAssessment: Equatable {
    enum Kind { case waiting, unknown, good, warning, error }
    let kind: Kind
    let message: String

    var level: LogLevel {
        switch kind {
        case .waiting: .debug
        case .unknown, .warning: .warning
        case .good: .info
        case .error: .error
        }
    }

    func combining(_ local: StreamHealth) -> StreamHealth {
        // Remote health can worsen local health, but never hide a capture/upload failure.
        guard local != .silenced, local != .unusable else { return local }
        switch kind {
        case .error: return .unusable
        case .warning, .unknown: return .degraded
        case .waiting: return local == .degraded ? .degraded : .awaiting
        case .good: return local
        }
    }

    static func evaluate(_ report: YouTubeIngestStatus?, startedAt: Date, receivedAt: Date?, now: Date) -> Self {
        let starting = now.timeIntervalSince(startedAt) < 60
        func unknown(_ message: String) -> Self {
            Self(kind: starting ? .waiting : .unknown, message: message)
        }
        guard let report, let receivedAt else { return unknown("YouTube ingest health is not available yet") }
        guard now.timeIntervalSince(receivedAt) <= 120 else {
            return unknown("YouTube ingest health has not been refreshed; current status is unknown")
        }
        if report.streamStatus == "error" {
            return Self(kind: .error, message: "YouTube reports an ingest error; check stream configuration")
        }
        guard report.streamStatus == "active" else {
            return unknown("YouTube has not confirmed an active incoming stream (\(report.streamStatus ?? "unknown"))")
        }
        guard let health = report.healthStatus, health.status != "noData" else {
            return unknown("YouTube is receiving the stream but has no ingest health report yet")
        }
        if let timestamp = health.lastUpdateTimeSeconds {
            let age = now.timeIntervalSince1970 - timestamp
            guard timestamp >= startedAt.timeIntervalSince1970 - 5, age <= 120, age >= -60 else {
                return unknown("YouTube's ingest health report is stale; current status is unknown")
            }
        }
        let issues = health.configurationIssues ?? []
        if health.status == "bad" || issues.contains(where: { $0.severity == "error" }) {
            return Self(kind: .error, message: "YouTube reports a stream configuration error; see the log")
        }
        if health.status == "ok" || issues.contains(where: { $0.severity != "info" }) {
            return Self(kind: .warning, message: "YouTube reports a stream configuration warning; see the log")
        }
        guard health.status == "good" else { return unknown("YouTube ingest health is unknown") }
        return Self(kind: .good, message: "YouTube reports healthy ingest")
    }
}

@Observable @MainActor
final class YouTubeStreamHealthMonitor {
    typealias Fetch = @MainActor (YouTubeHealthTarget) async throws -> YouTubeIngestStatus
    private(set) var target: YouTubeHealthTarget?
    private(set) var report: YouTubeIngestStatus?
    private var startedAt = Date()
    private(set) var receivedAt: Date?
    var lastRefreshSucceeded: Bool { receivedAt != nil && lastFailure == nil }
    private var requestID: UUID?
    private var lastAssessment: YouTubeHealthAssessment?
    private var lastIssues: Set<String> = []
    private var lastIssuesWereActionable = false
    private var lastFailure: String?
    private var consecutiveFailures = 0
    private let now: () -> Date
    private let log: (String, LogLevel) -> Void

    init(now: @escaping () -> Date = Date.init, log: @escaping (String, LogLevel) -> Void = { LOG($0, level: $1) }) {
        self.now = now
        self.log = log
    }

    var assessment: YouTubeHealthAssessment {
        let result = YouTubeHealthAssessment.evaluate(report, startedAt: startedAt, receivedAt: receivedAt, now: now())
        if lastFailure != nil, result.kind != .error {
            return .init(kind: .unknown, message: "YouTube health check is unavailable; uploads continue")
        }
        return result
    }

    func configure(_ target: YouTubeHealthTarget?) {
        guard self.target != target else { return }
        self.target = target
        startedAt = now()
        report = nil
        receivedAt = nil
        requestID = nil
        lastAssessment = nil
        lastIssues = []
        lastIssuesWereActionable = false
        lastFailure = nil
        consecutiveFailures = 0
    }

    var pollingInterval: TimeInterval {
        if consecutiveFailures > 0 { return min(300, 30 * pow(2, Double(min(consecutiveFailures, 4)))) }
        if now().timeIntervalSince(startedAt) < 120 { return 10 }
        return assessment.kind == .good ? 60 : 30
    }

    func run(target: YouTubeHealthTarget, fetch: Fetch, notice: (String) -> Void) async {
        log("YouTube ingest monitoring started; stream=\(YouTubeDiagnostics.text(target.streamID)); broadcast=\(YouTubeDiagnostics.text(target.broadcastID))", .debug)
        while !Task.isCancelled, self.target == target {
            await refresh(target: target, fetch: fetch, notice: notice)
            do { try await Task.sleep(for: .seconds(pollingInterval)) }
            catch { return }
        }
    }

    func refresh(target: YouTubeHealthTarget, fetch: Fetch, notice: (String) -> Void) async {
        guard !Task.isCancelled, self.target == target, requestID == nil else { return }
        let request = UUID()
        requestID = request
        defer { if requestID == request { requestID = nil } }
        do {
            let status = try await fetch(target)
            guard !Task.isCancelled, self.target == target, requestID == request else { return }
            report = status
            receivedAt = now()
            consecutiveFailures = 0
            if lastFailure != nil { log("YouTube ingest health checks resumed", .info) }
            lastFailure = nil
            let timestamp = status.healthStatus?.lastUpdateTimeSeconds.map { String(format: "%.0f", $0) } ?? "unavailable"
            log("YouTube ingest: stream=\(status.streamStatus ?? "unknown"); health=\(status.healthStatus?.status ?? "unknown"); updated=\(timestamp); issues=\(status.healthStatus?.configurationIssues?.count ?? 0)", .debug)
            publishAssessment(notice: notice)
        } catch {
            guard !Task.isCancelled, !YouTubeDiagnostics.isCancellation(error), self.target == target,
                  requestID == request else { return }
            consecutiveFailures += 1
            let failure = YouTubeDiagnostics.failure(error)
            if lastFailure != failure {
                log("YouTube ingest health check unavailable (\(failure)); uploads continue", .warning)
            }
            lastFailure = failure
            // An API outage is not an encoder/ingest failure. Keep a recent confirmed
            // error, but never show green based solely on an old successful check.
        }
    }

    private func publishAssessment(notice: (String) -> Void) {
        let current = assessment
        let issues = report?.healthStatus?.configurationIssues ?? []
        let signatures = Set(issues.map(\.diagnostic))
        let actionable = current.kind == .error || current.kind == .warning
        if current != lastAssessment {
            log(current.message, current.level)
            if current.kind == .error || current.kind == .warning || current.kind == .unknown {
                notice(current.message)
            }
        } else if actionable, !signatures.subtracting(lastIssues).isEmpty {
            notice(current.message)
        }
        for issue in issues where !lastIssues.contains(issue.diagnostic) || (actionable && !lastIssuesWereActionable) {
            let level: LogLevel = !actionable || issue.severity == "info" ? .debug
                : issue.severity == "error" ? .error : .warning
            log("YouTube configuration: \(issue.diagnostic)", level)
        }
        // A stale issue logged at debug must be reported when it becomes current.
        lastIssues = signatures
        lastIssuesWereActionable = actionable
        lastAssessment = current
    }
}
