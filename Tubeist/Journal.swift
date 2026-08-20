//
//  Logger.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-15.
//

import OSLog
import Foundation
import SwiftUI
import Observation

func LOG(_ message: String, level: LogLevel = .info) {
    Journal.shared.log(message, level: level)
}

enum LogLevel: Hashable, Sendable {
    case debug
    case info
    case warning
    case error
    
    var color: Color {
        switch self {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let message: String
    let level: LogLevel
    var timestamp: Date = Date()
    var repeatCount: Int = 1
}

actor JournalActor {
    // Observable property for tracking error presence
    public var hasErrors = false
    private var levels: Set<LogLevel> = []
    private var messageOrder: [String] = []
    private var journal: [String: LogEntry] = [:]
    private let entryLimit: Int

    init(entryLimit: Int = MAX_LOG_ENTRIES) {
        self.entryLimit = max(1, entryLimit)
    }

    func log(message: String, level: LogLevel) {
        guard isLogging(level: level) else { return }
        if var existingEntry = journal[message] {
            existingEntry.timestamp = Date()
            existingEntry.repeatCount += 1
            journal[message] = existingEntry
            messageOrder.removeAll { $0 == message }
        }
        else {
            journal[message] = LogEntry(message: message, level: level)
        }
        messageOrder.append(message)
        if level == .error {
            hasErrors = true
        }
        if journal.count > entryLimit, let oldestMessage = messageOrder.first {
            journal[oldestMessage] = nil
            messageOrder.removeFirst()
        }
    }
    func getJournal() -> [LogEntry] {
        Array(journal.values).sorted(by: { $0.timestamp < $1.timestamp })
    }
    func clearJournal() {
        journal.removeAll()
        messageOrder.removeAll()
        hasErrors = false
    }
    func enable(level: LogLevel) {
        levels.insert(level)
    }
    func disable(level: LogLevel) {
        levels.remove(level)
    }
    func isLogging(level: LogLevel) -> Bool {
        levels.contains(level)
    }
}

@Observable @MainActor
final class JournalPublisher {
    var journal: [LogEntry] = []
    var hasErrors: Bool = false
}

final class Journal: Sendable {
    static let shared = Journal()
    @MainActor public static let publisher = JournalPublisher()
    private let journal = JournalActor()
    private let logger: Logger
    private let publicationGate = JournalPublicationGate()
    private let submissionGate = JournalSubmissionGate(limit: 1_024)
    
    private init() {
        logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.subside.Tubeist", category: "general")
    }
    
    func log(_ message: String, level: LogLevel = .info) {
        // Log to system console
        switch level {
        case .debug:
            logger.debug("\(message)")
        case .info:
            logger.info("\(message)")
        case .warning:
            logger.warning("\(message)")
        case .error:
            logger.error("\(message)")
        }
        
        if submissionGate.append(JournalSubmission(message: message, level: level)) {
            Task { [self] in
                await drainSubmissions()
            }
        }
    }
    
    func getJournal() async -> [LogEntry] {
        return await journal.getJournal()
    }
    
    func clearJournal() {
        Task {
            await journal.clearJournal()
            schedulePublication()
        }
    }
    
    func enable(level: LogLevel) async {
        await journal.enable(level: level)
    }
    func disable(level: LogLevel) async {
        await journal.disable(level: level)
    }

    private func schedulePublication() {
        guard publicationGate.claim() else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            publicationGate.release()
            let entries = await journal.getJournal()
            let hasErrors = await journal.hasErrors
            await MainActor.run {
                Journal.publisher.journal = entries
                Journal.publisher.hasErrors = hasErrors
            }
        }
    }

    private func drainSubmissions() async {
        while let batch = submissionGate.takeBatch() {
            if batch.dropped > 0 {
                await journal.log(
                    message: "Journal dropped \(batch.dropped) queued messages during overload",
                    level: .warning
                )
            }
            for submission in batch.submissions {
                await journal.log(message: submission.message, level: submission.level)
            }
            schedulePublication()
        }
    }
}

private struct JournalSubmission: Sendable {
    let message: String
    let level: LogLevel
}

private struct JournalSubmissionBatch: Sendable {
    let submissions: [JournalSubmission]
    let dropped: Int
}

/// Coalesces concurrent synchronous log calls behind one asynchronous drain.
private final class JournalSubmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var submissions: [JournalSubmission] = []
    private var isDraining = false
    private var dropped = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Returns true when the caller must start the single drain task.
    func append(_ submission: JournalSubmission) -> Bool {
        lock.withLock {
            if submissions.count >= limit {
                submissions.removeFirst(submissions.count - limit + 1)
                dropped += 1
            }
            submissions.append(submission)
            guard !isDraining else { return false }
            isDraining = true
            return true
        }
    }

    func takeBatch() -> JournalSubmissionBatch? {
        lock.withLock {
            guard !submissions.isEmpty else {
                isDraining = false
                return nil
            }
            let batch = JournalSubmissionBatch(submissions: submissions, dropped: dropped)
            submissions.removeAll(keepingCapacity: true)
            dropped = 0
            return batch
        }
    }
}

private final class JournalPublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !isClaimed else { return false }
            isClaimed = true
            return true
        }
    }

    func release() {
        lock.withLock { isClaimed = false }
    }
}


struct JournalView: View {
    @State var journalPublisher = Journal.publisher
    private let hh_mm_ss = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm ss"
        return formatter
    }()
    private let almostBlack = Color(red: 0.1, green: 0.1, blue: 0.1)
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(journalPublisher.journal.reversed()) { log in
                    HStack(alignment: .top) {
                        Text(log.timestamp, formatter: hh_mm_ss)
                            .font(.caption2)
                            .padding(.top, 1)
                            .monospacedDigit()
                        Text(log.repeatCount.description)
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .padding(.top, 1)
                            .frame(minWidth: 15)
                        Text(log.message)
                            .font(.caption)
                            .foregroundColor(log.level.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .frame(height: 1)
                            .foregroundColor(almostBlack)
                            .padding(.horizontal)
                    }
                }
            }
        }
        .background(Color.black)
    }
}
