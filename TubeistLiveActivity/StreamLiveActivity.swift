import ActivityKit
import SwiftUI
import WidgetKit

struct StreamLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StreamActivityAttributes.self) { context in
            StreamActivityView(state: context.state, startedAt: context.attributes.startedAt)
                .padding()
                .activityBackgroundTint(.black.opacity(0.85))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HealthBadge(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StreamDetailRows(state: context.state)
                }
            } compactLeading: {
                HealthDot(state: context.state)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
            } minimal: {
                HealthDot(state: context.state)
            }
        }
        // Opt in to the compact Smart Stack layout used on Apple Watch.
        .supplementalActivityFamilies([.small])
    }
}

struct StreamActivityView: View {
    @Environment(\.activityFamily) private var family
    let state: StreamActivityAttributes.ContentState
    let startedAt: Date

    var body: some View {
        switch family {
        case .small:
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    HealthBadge(state: state)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if state.phase == .live {
                        Spacer(minLength: 4)
                        SaveHighlightButton(compact: true)
                    }
                }
                Text(startedAt, style: .timer).monospacedDigit().font(.caption)
                if let status = state.highlightStatus {
                    Text(status.label).font(.caption2).foregroundStyle(.secondary)
                } else if let viewers = state.viewers {
                    Label("\(viewers)", systemImage: "eye").font(.caption2)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    HealthBadge(state: state)
                    Spacer()
                    Text(startedAt, style: .timer).monospacedDigit()
                }
                StreamDetailRows(state: state)
                if state.phase == .live {
                    SaveHighlightButton(compact: false)
                }
            }
        }
    }
}

struct StreamDetailRows: View {
    let state: StreamActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let warning = state.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let status = state.highlightStatus {
                Label(status.label, systemImage: "bolt.badge.clock")
                    .foregroundStyle(status == .failed ? .red : .secondary)
            }
            HStack(spacing: 12) {
                if let viewers = state.viewers { Label("\(viewers)", systemImage: "eye") }
                if let bitrate = state.bitrateLabel { Label(bitrate, systemImage: "arrow.up") }
                if let battery = state.batteryPercent { Label("\(battery)%", systemImage: "battery.75") }
                if let link = state.link, link != .good, link != .unknown {
                    Label(link.rawValue.capitalized, systemImage: "wifi")
                        .foregroundStyle(link == .degraded ? .yellow : .red)
                }
                if let thermal = state.thermal, thermal != .nominal {
                    Label(thermal.rawValue.capitalized, systemImage: "thermometer.medium")
                        .foregroundStyle(thermal == .fair ? .yellow : .red)
                }
            }
            .font(.caption)
        }
    }
}

struct HealthBadge: View {
    let state: StreamActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            HealthDot(state: state)
            Text(label).font(.headline)
        }
    }

    private var label: String {
        switch state.phase {
        case .connecting: "Connecting"
        case .stopping: "Stopping"
        // Local capture is done; YouTube hasn't confirmed the broadcast is
        // complete yet, so the raw status is more honest than a fixed label.
        case .finalizing: state.youtubeStatusLabel.map { "YouTube: \($0.capitalized)" } ?? "Finalizing"
        case .ended: "Ended"
        // With no bound YouTube stream there is no health to report, so the badge
        // says only that the stream is live rather than an unanswerable "Live ?".
        case .live: if !state.healthTracked {
            "Live"
        } else {
            state.isStale ? "Live ?" : "Live · \(state.health.label)"
        }
        }
    }
}

struct HealthDot: View {
    let state: StreamActivityAttributes.ContentState

    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
    }

    private var color: Color {
        // Untracked health gets the neutral dot: no health was promised, so neither a
        // green "all good" nor a grey "something is wrong" would be honest.
        if state.phase != .live || state.isStale || !state.healthTracked { return .gray }
        switch state.health {
        case .good: return .green
        case .ok: return .yellow
        case .bad, .noData: return .red
        case .unknown: return .gray
        }
    }
}

/// Runs SaveHighlightIntent, which ActivityKit runs in the app's process (not
/// this widget extension) because it conforms to LiveActivityIntent — the
/// same button works from the Lock Screen, Dynamic Island and the Watch
/// Smart Stack without a separate watchOS app.
struct SaveHighlightButton: View {
    let compact: Bool

    var body: some View {
        Button(intent: SaveHighlightIntent()) {
            if compact {
                Image(systemName: "bolt.badge.clock")
            } else {
                Label("Highlight", systemImage: "bolt.badge.clock")
                    .font(.caption)
            }
        }
        // .bordered draws a filled capsule that IS the hit-testable region,
        // unlike .plain (whose tap target is just the glyph/label bounds) —
        // in the Smart Stack's tiny card that ambiguity let taps fall through
        // to the card's own "open Live Activity" gesture instead of the button.
        // .bordered's default padding is sized for a normal-width screen, not
        // this card, so it swallowed the health text next to it — .mini keeps
        // the reliable hit region but at a footprint that actually fits.
        .buttonStyle(.bordered)
        .controlSize(compact ? .mini : .regular)
        .tint(.yellow)
    }
}
