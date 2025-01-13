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
    let message: String
    let level: LogLevel
    var timestamp: Date = Date()
    var repeatCount: Int = 1
}

actor JournalActor {
    // Observable property for tracking error presence
    public var hasErrors = false
    private var messageOrder: [String] = []
    private var journal: [String: LogEntry] = [:]
    func log(message: String, level: LogLevel) {
        messageOrder.append(message)
        if var existingEntry = journal[message] {
            existingEntry.timestamp = Date()
            existingEntry.repeatCount += 1
            journal[message] = existingEntry
        }
        else {
            journal[message] = LogEntry(message: message, level: level)
        }
        if level == .error {
            hasErrors = true
        }
        if journal.count > MAX_LOG_ENTRIES {
            let oldestMessage = messageOrder.first!
            journal[oldestMessage] = nil
            messageOrder.removeAll(where: { $0 == oldestMessage })
        }
    }
    func getJournal() -> [LogEntry] {
        Array(journal.values).sorted(by: { $0.timestamp < $1.timestamp })
    }
    func clearJournal() {
        journal.removeAll()
        hasErrors = false
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
        
        // updates must happen on MainActor (UI related)
        Task { @MainActor in
            await journal.log(message: message, level: level)
            Journal.publisher.journal = await journal.getJournal()
            Journal.publisher.hasErrors = await journal.hasErrors
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
                            .font(.system(size: 12))
                            .padding(.top, 1)
                            .monospacedDigit()
                        Text(log.repeatCount.description)
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                            .padding(.top, 1)
                            .frame(minWidth: 15)
                        Text(log.message)
                            .font(.system(size: 14))
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
