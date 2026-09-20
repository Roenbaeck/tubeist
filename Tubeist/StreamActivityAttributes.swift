//
//  StreamActivityAttributes.swift
//  Tubeist
//
//  Types shared by the app and the TubeistLiveActivity widget extension.
//  Keep this file free of app-only dependencies.
//

import ActivityKit
import Foundation

enum YouTubeStreamHealth: String, Codable, Sendable {
    case good, ok, bad, noData, unknown

    /// Maps YouTube's `status.healthStatus.status` value.
    init(apiValue: String?) {
        switch apiValue {
        case "good": self = .good
        case "ok": self = .ok
        case "bad": self = .bad
        case "noData": self = .noData
        default: self = .unknown
        }
    }

    var isAlarming: Bool { self == .bad || self == .noData }

    var label: String {
        switch self {
        case .good: "Good"
        case .ok: "OK"
        case .bad: "Bad"
        case .noData: "No data"
        case .unknown: "Unknown"
        }
    }
}

enum LinkQuality: String, Codable, Sendable {
    case unknown, good, degraded, poor
}

enum ThermalLevel: String, Codable, Sendable {
    case nominal, fair, serious, critical
}

enum StreamPhase: String, Codable, Sendable {
    case connecting, live, stopping, ended
}

struct StreamActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: StreamPhase
        var health: YouTubeStreamHealth
        /// True when the health value is older than the stale threshold.
        var isStale: Bool
        var warning: String?
        // Full detail only; nil means "do not show".
        var viewers: Int?
        var bitrateKbps: Int?
        var link: LinkQuality?
        var thermal: ThermalLevel?
        var batteryPercent: Int?
    }

    /// When the stream went live; drives the elapsed-time timer.
    var startedAt: Date
}
