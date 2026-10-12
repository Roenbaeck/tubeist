// Shared by the iPhone app and its Live Activity extension.
import ActivityKit
import Foundation

struct StreamActivityAttributes: ActivityAttributes {
    let sessionID: UUID

    struct ContentState: Codable, Hashable, Sendable {
        var phase: StreamActivityPhase
        var startedAt: Date?
        /// Freeze the elapsed timer when capture stops, including during finalization.
        var stoppedAt: Date?
        var health: StreamActivityHealth
        var healthTracked: Bool
        var link: StreamActivityLink
        var viewers: Int?
        var bitrateKbps: Int?
        var batteryPercent: Int?
        var thermal: StreamActivityThermal?
        var fullDetail: Bool
        var isDemo = false
        var healthValidUntil: Date? = nil
        var canSaveHighlight = false
        var highlightStatus: HighlightStatus? = nil

        var status: String {
            switch phase {
            case .preparing: return "Getting ready"
            case .finishing: return "Finalizing output"
            case .ended: return "Session finished"
            case .failed: return "Check the Tubeist log"
            case .recording: return "Saving on iPhone"
            case .streaming:
                if link == .failed { return link.title }
                if healthTracked, health == .error { return health.title }
                if link == .degraded { return link.title }
                return healthTracked ? health.title : "YouTube health unavailable"
            }
        }

        var bitrateLabel: String? { bitrateKbps.map(Self.bitrateLabel) }
        static func bitrateLabel(kbps: Int) -> String {
            kbps >= 1000 ? String(format: "%.1f Mbps", Double(kbps) / 1000) : "\(kbps) kbps"
        }
    }
}
