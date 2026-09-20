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
                HealthBadge(state: state)
                Text(startedAt, style: .timer).monospacedDigit().font(.caption)
                if let viewers = state.viewers {
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
            HStack(spacing: 12) {
                if let viewers = state.viewers { Label("\(viewers)", systemImage: "eye") }
                if let kbps = state.bitrateKbps { Label("\(kbps / 1000) Mbps", systemImage: "arrow.up") }
                if let battery = state.batteryPercent { Label("\(battery)%", systemImage: "battery.75") }
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
        case .ended: "Ended"
        case .live: state.isStale ? "Live ?" : "Live · \(state.health.label)"
        }
    }
}

struct HealthDot: View {
    let state: StreamActivityAttributes.ContentState

    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
    }

    private var color: Color {
        if state.phase != .live || state.isStale { return .gray }
        switch state.health {
        case .good: return .green
        case .ok: return .yellow
        case .bad, .noData: return .red
        case .unknown: return .gray
        }
    }
}
