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
    /// Local capture/upload has finished, but YouTube's backend hasn't yet
    /// reported the broadcast as complete — it can take minutes longer than
    /// the local stop. See stopYouTubePolling() in TubeistView.swift.
    case connecting, live, stopping, finalizing, ended
}

/// A transient overlay shown inline while/after a highlight save runs, so a
/// Live Activity/Watch button press has visible feedback well before the
/// save actually finishes. Coordinator-managed: cleared a few seconds after
/// being set, independent of the normal stream content fields below.
enum HighlightStatus: String, Codable, Sendable, Hashable {
    case saving, saved, failed

    var label: String {
        switch self {
        case .saving: "Saving highlight…"
        case .saved: "Highlight saved"
        case .failed: "Highlight failed"
        }
    }
}

struct StreamActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: StreamPhase
        var health: YouTubeStreamHealth
        /// False when no YouTube stream is bound (manual stream key, or not signed
        /// in), so there is no health to report. The UI then shows a plain "Live"
        /// rather than an unanswerable "Live ?", and health never goes stale.
        var healthTracked: Bool = true
        /// True when the health value is older than the stale threshold.
        var isStale: Bool
        var warning: String?
        // Full detail only; nil means "do not show".
        var viewers: Int?
        var bitrateKbps: Int?
        var link: LinkQuality?
        var thermal: ThermalLevel?
        var batteryPercent: Int?
        var highlightStatus: HighlightStatus?
        /// YouTube's raw broadcast lifecycle status (e.g. "live", "complete"),
        /// shown only while phase == .finalizing.
        var youtubeStatusLabel: String?
    }

    /// When the stream went live; drives the elapsed-time timer.
    var startedAt: Date
}

extension StreamActivityAttributes.ContentState {
    /// Human-readable uplink rate, or nil when the bitrate is unknown.
    var bitrateLabel: String? {
        bitrateKbps.map(Self.bitrateLabel(kbps:))
    }

    /// Formats a kbps value for display.
    ///
    /// Integer division by 1000 would round 4500 kbps down to "4 Mbps" and hide any
    /// sub-megabit uplink behind "0 Mbps", so megabits carry one decimal and anything
    /// below 1 Mbps stays in kbps.
    static func bitrateLabel(kbps: Int) -> String {
        kbps >= 1000 ? String(format: "%.1f Mbps", Double(kbps) / 1000) : "\(kbps) kbps"
    }
}
