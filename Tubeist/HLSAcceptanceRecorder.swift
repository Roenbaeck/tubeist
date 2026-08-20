//
//  HLSAcceptanceRecorder.swift
//  Tubeist
//

#if DEBUG
import Foundation

actor HLSAcceptanceRecorder {
    static let shared = HLSAcceptanceRecorder()

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

    private let maximumEvents = 10_000
    private let batchSize = 16
    private var fileHandle: FileHandle?
    private var bufferedLines: [Data] = []
    private var eventCount = 0

    func begin(sessionIdentifier: String, enabled: Bool) {
        closeFile()
        guard enabled,
              let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
              ).first else { return }

        let directory = documents
            .appendingPathComponent("TubeistDirectHLSAcceptance", isDirectory: true)
            .appendingPathComponent(sessionIdentifier, isDirectory: true)
        let reportURL = directory.appendingPathComponent("acceptance.jsonl")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: reportURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            fileHandle = try FileHandle(forWritingTo: reportURL)
            eventCount = 0
            bufferedLines.removeAll(keepingCapacity: true)
            append(kind: "prepared", detail: "schema=2")
        } catch {
            closeFile()
            LOG("Could not create the YouTube HLS acceptance report", level: .warning)
        }
    }

    func initializationParsed() { append(kind: "initializationParsed") }

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
        append(kind: "segmentDropped", sequence: sequence, droppedFragments: droppedFragments)
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
        guard fileHandle != nil, eventCount < maximumEvents else { return }
        let event = Event(
            timestamp: Date(),
            kind: kind,
            sequence: sequence,
            duration: duration,
            queuedDuration: queuedDuration,
            retryCount: retryCount,
            httpStatus: httpStatus,
            droppedFragments: droppedFragments,
            detail: detail
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            var line = try encoder.encode(event)
            line.append(0x0A)
            bufferedLines.append(line)
            eventCount += 1
            if bufferedLines.count >= batchSize {
                try flush()
            }
        } catch {
            LOG("Could not append to the YouTube HLS acceptance report", level: .warning)
            closeFile()
        }
    }

    private func finish(outcome: String) {
        append(kind: "summary", detail: "outcome=\(outcome);events=\(eventCount)")
        do {
            try flush()
            try fileHandle?.synchronize()
        } catch {
            LOG("Could not finalize the YouTube HLS acceptance report", level: .warning)
        }
        closeFile()
    }

    private func flush() throws {
        guard let fileHandle, !bufferedLines.isEmpty else { return }
        var batch = Data()
        batch.reserveCapacity(bufferedLines.reduce(0) { $0 + $1.count })
        bufferedLines.forEach { batch.append($0) }
        try fileHandle.write(contentsOf: batch)
        bufferedLines.removeAll(keepingCapacity: true)
    }

    private func closeFile() {
        try? fileHandle?.close()
        fileHandle = nil
        bufferedLines.removeAll(keepingCapacity: false)
        eventCount = 0
    }
}
#endif
