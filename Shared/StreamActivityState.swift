// Plain state enums shared by the iPhone app, its Live Activity extension,
// and TubeistWatch. Deliberately has no ActivityKit import (unlike
// StreamActivityAttributes.swift) since ActivityKit isn't resolvable as a
// watchOS app module — this file is what the Watch target actually needs.
import Foundation

enum StreamActivityPhase: String, Codable, Sendable {
    case preparing, streaming, recording, finishing, ended, failed

    var title: String {
        switch self {
        case .preparing: "Preparing"
        case .streaming: "Live"
        case .recording: "Recording"
        case .finishing: "Finishing"
        case .ended: "Ended"
        case .failed: "Stopped"
        }
    }
    var isTerminal: Bool { self == .ended || self == .failed }
}

enum StreamActivityHealth: String, Codable, Sendable {
    case waiting, unknown, good, warning, error
    var title: String {
        switch self {
        case .waiting: "Waiting for YouTube"
        case .unknown: "Health unavailable"
        case .good: "YouTube healthy"
        case .warning: "Stream warning"
        case .error: "Stream problem"
        }
    }
}

enum StreamActivityLink: String, Codable, Sendable {
    case unknown, good, degraded, failed
    var title: String {
        switch self {
        case .unknown: "Checking upload"
        case .good: "Upload OK"
        case .degraded: "Upload slow"
        case .failed: "Upload problem"
        }
    }
}

enum StreamActivityThermal: String, Codable, Sendable {
    case normal, warm, hot, critical
    var title: String { rawValue.capitalized }
}

enum HighlightStatus: String, Codable, Sendable {
    case saving, saved, failed
    var label: String {
        switch self {
        case .saving: "Saving highlight…"
        case .saved: "Highlight saved"
        case .failed: "Highlight failed"
        }
    }
}
