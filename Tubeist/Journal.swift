//
//  Logger.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-15.
//

import OSLog
import Foundation
import SwiftUI

enum LogLevel {
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

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let message: String
}

actor JournalActor {
    // Observable property for tracking error presence
    var hasErrors = false
    private var journal: [LogEntry] = []
    func log(_ logEntry: LogEntry) {
        journal.append(logEntry)
        // Update error tracking
        if logEntry.level == .error {
            hasErrors = true
        }
        // Optional: Limit log store size
        if journal.count > MAX_LOG_ENTRIES {
            journal.removeFirst()
        }
    }
    func getJournal() -> [LogEntry] {
        journal
    }
    func clearJournal() {
        journal.removeAll()
        hasErrors = false
    }
}

final class Journal: Sendable {
    static let shared = Journal()
    private let journal = JournalActor()
    private let logger: Logger
    
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
        
        // Store in log store
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        Task {
            await journal.log(entry)
        }
    }
    
    func getJournal() async -> [LogEntry] {
        return await journal.getJournal()
    }
    
    func clearJournal() {
        Task {
            await journal.clearJournal()
        }
    }
}

// SwiftUI View to display logs
struct JournalView: View {
    @State private var logs: [LogEntry] = []
    
    var body: some View {
        List(logs) { log in
            HStack {
                Text(log.timestamp, style: .time)
                Text(log.message)
                    .foregroundColor(log.level.color)
            }
        }
        .onAppear {
            Task {
                logs = await Journal.shared.getJournal()
            }
        }
    }
}