import SwiftUI
import WidgetKit

struct StreamActivityView: View {
    @Environment(\.activityFamily) private var family
    @Environment(\.isLuminanceReduced) private var dimmed
    let state: StreamActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: family == .small ? 4 : 8) {
            HStack {
                StreamActivityBadge(state: state, stale: stale)
                Spacer(minLength: 4)
                StreamActivityTimer(state: state)
            }
            .font(family == .small ? .caption : .headline)
            Text(stale && !state.phase.isTerminal ? "Status unavailable" : state.status)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if state.fullDetail, !stale, !state.phase.isTerminal {
                HStack {
                    if let bitrate = state.bitrateLabel {
                        Label(bitrate, systemImage: "arrow.up")
                    }
                    Spacer(minLength: 4)
                    if let viewers = state.viewers { Label(viewers.formatted(), systemImage: "eye") }
                }
                HStack(spacing: 7) {
                    if let battery = state.batteryPercent {
                        Label("\(battery)%", systemImage: "battery.75percent")
                            .foregroundStyle(battery <= 20 ? Color.orange : Color.white.opacity(0.8))
                    }
                    Spacer(minLength: 2)
                    if let thermal = state.thermal {
                        Label(thermal.title, systemImage: "thermometer.medium")
                            .foregroundStyle(thermal == .hot || thermal == .critical ? Color.orange : Color.white.opacity(0.8))
                    }
                    if state.phase == .streaming {
                        Image(systemName: state.link == .failed ? "wifi.exclamationmark" : "wifi")
                            .foregroundStyle(state.link == .good ? .green : state.link == .degraded ? .yellow : .gray)
                            .accessibilityLabel(state.link.title)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
        .font(.caption2)
        .foregroundStyle(.white)
        .opacity(dimmed ? 0.65 : 1)
    }
}

struct StreamActivityBadge: View {
    let state: StreamActivityAttributes.ContentState
    let stale: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(StreamActivityAppearance.color(state, stale: stale)).frame(width: 7, height: 7)
            Text(state.isDemo ? "Demo · \(state.phase.title)" : state.phase.title)
                .fontWeight(.semibold).lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StreamActivityTimer: View {
    let state: StreamActivityAttributes.ContentState
    var body: some View {
        if let start = state.startedAt {
            if let end = state.stoppedAt {
                Text(Duration.seconds(max(0, end.timeIntervalSince(start))), format: .time(pattern: .hourMinuteSecond))
                    .monospacedDigit()
            } else {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
            }
        } else {
            Text("—").accessibilityLabel("Not started")
        }
    }
}

enum StreamActivityAppearance {
    static func color(_ state: StreamActivityAttributes.ContentState, stale: Bool) -> Color {
        if state.phase == .failed { return .red }
        if stale || state.phase == .ended || state.phase == .preparing || state.phase == .finishing { return .gray }
        if state.phase == .recording { return .red }
        if state.link == .failed || state.health == .error { return .red }
        if state.link == .degraded || state.health == .warning { return .yellow }
        if state.healthTracked && state.health == .good && state.link == .good { return .green }
        return .gray
    }
}

