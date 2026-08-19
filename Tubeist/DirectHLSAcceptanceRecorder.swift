//
//  DirectHLSAcceptanceRecorder.swift
//  Tubeist
//

#if DEBUG
import Foundation

actor DirectHLSAcceptanceRecorder {
    static let shared = DirectHLSAcceptanceRecorder()

    private struct Event: Codable {
        let timestamp: Date
        let kind: String
        let sequence: Int?
        let duration: Double?
        let queuedDuration: Double?
        let retryCount: Int?
        let httpStatus: Int?
        let droppedFragments: Int?
        let detail: String?
    }

    private struct Report: Codable {
        let schemaVersion: Int
        let sessionIdentifier: String
        let startedAt: Date
        var endedAt: Date?
        var outcome: String?
        var events: [Event]
    }

    private var report: Report?
    private var reportURL: URL?

    func begin(sessionIdentifier: String, enabled: Bool) {
        report = nil
        reportURL = nil
        guard enabled,
              let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
              ).first else {
            return
        }

        let directory = documents
            .appendingPathComponent("TubeistDirectHLSAcceptance", isDirectory: true)
            .appendingPathComponent(sessionIdentifier, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            report = Report(
                schemaVersion: 1,
                sessionIdentifier: sessionIdentifier,
                startedAt: Date(),
                endedAt: nil,
                outcome: nil,
                events: []
            )
            reportURL = directory.appendingPathComponent("acceptance.json")
            append(kind: "prepared")
        } catch {
            report = nil
            reportURL = nil
            LOG("Could not create the direct-HLS acceptance report", level: .warning)
        }
    }

    func initializationParsed() {
        append(kind: "initializationParsed")
    }

    func segmentAccepted(
        sequence: Int,
        duration: Double,
        queuedDuration: Double,
        retryCount: Int,
        httpStatus: Int?
    ) {
        append(
            kind: "segmentAccepted",
            sequence: sequence,
            duration: duration,
            queuedDuration: queuedDuration,
            retryCount: retryCount,
            httpStatus: httpStatus
        )
    }

    func segmentDropped(sequence: Int, droppedFragments: Int) {
        append(
            kind: "segmentDropped",
            sequence: sequence,
            droppedFragments: droppedFragments
        )
    }

    func failed(_ detail: String) {
        append(kind: "failed", detail: detail)
        finish(outcome: "failed")
    }

    func stopped() {
        append(kind: "stopped")
        finish(outcome: "stopped")
    }

    func cancelled() {
        append(kind: "cancelled")
        finish(outcome: "cancelled")
    }

    private func append(
        kind: String,
        sequence: Int? = nil,
        duration: Double? = nil,
        queuedDuration: Double? = nil,
        retryCount: Int? = nil,
        httpStatus: Int? = nil,
        droppedFragments: Int? = nil,
        detail: String? = nil
    ) {
        guard report != nil else { return }
        report?.events.append(Event(
            timestamp: Date(),
            kind: kind,
            sequence: sequence,
            duration: duration,
            queuedDuration: queuedDuration,
            retryCount: retryCount,
            httpStatus: httpStatus,
            droppedFragments: droppedFragments,
            detail: detail
        ))
        persist()
    }

    private func finish(outcome: String) {
        guard report != nil else { return }
        report?.endedAt = Date()
        report?.outcome = outcome
        persist()
    }

    private func persist() {
        guard let report, let reportURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
        } catch {
            LOG("Could not update the direct-HLS acceptance report", level: .warning)
        }
    }
}
#endif
