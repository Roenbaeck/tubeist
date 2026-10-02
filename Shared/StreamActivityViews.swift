import SwiftUI
import WidgetKit

/// The Watch Smart Stack has much less vertical space than the iPhone activity.
struct StreamActivityCard: View {
    @Environment(\.activityFamily) private var family
    let state: StreamActivityAttributes.ContentState
    let stale: Bool
    var highlightSessionID: UUID? = nil

    var body: some View {
        StreamActivityView(state: state, stale: stale, highlightSessionID: highlightSessionID)
            .padding(.horizontal, family == .small ? 6 : 10)
            .padding(.vertical, family == .small ? 4 : 10)
            .frame(maxWidth: .infinity, maxHeight: family == .small ? .infinity : nil, alignment: .topLeading)
    }
}

struct StreamActivityView: View {
    @Environment(\.activityFamily) private var family
    @Environment(\.isLuminanceReduced) private var dimmed
    let state: StreamActivityAttributes.ContentState
    let stale: Bool
    var highlightSessionID: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            VStack(alignment: .leading, spacing: rowSpacing) {
                HStack(spacing: 4) {
                    StreamActivityBadge(state: state, stale: stale)
                        .accessibilityIdentifier("activity-phase")
                    if family != .small { Spacer(minLength: 4) }
                    StreamActivityTimer(state: state)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: family == .small ? 54 : nil, alignment: .leading)
                        .accessibilityIdentifier("activity-timer")
                    if family == .small { Spacer(minLength: 0) }
                }
                .font(family == .small ? .caption : .headline)
                Text(stale && !state.phase.isTerminal ? "Status unavailable" : state.status)
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityIdentifier("activity-health")
            }
            .padding(.trailing, showsHighlight || showsHighlightFeedback ? highlightSize + 6 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                if showsHighlight, let highlightSessionID {
                    Button(intent: SaveHighlightIntent(sessionID: highlightSessionID)) {
                        highlightIndicator
                    }
                    .disabled(state.highlightStatus == .saving)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Save highlight")
                    .accessibilityValue(state.highlightStatus?.label ?? "Ready")
                    .accessibilityHint("Saves about 10 seconds before and 5 seconds after this moment on the iPhone")
                    .accessibilityIdentifier("activity-save-highlight")
                } else if showsHighlightFeedback {
                    highlightIndicator
                        .accessibilityLabel(state.highlightStatus?.label ?? "")
                        .accessibilityIdentifier("activity-highlight-feedback")
                }
            }
            if state.fullDetail, !stale, !state.phase.isTerminal {
                HStack {
                    if let bitrate = state.bitrateLabel {
                        Label(bitrate, systemImage: "arrow.up")
                            .accessibilityIdentifier("activity-bitrate")
                    }
                    Spacer(minLength: 4)
                    if let viewers = state.viewers { Label(viewers.formatted(), systemImage: "eye") }
                }
                HStack(spacing: 7) {
                    if let battery = state.batteryPercent {
                        Label("\(battery)%", systemImage: "battery.75percent")
                            .foregroundStyle(battery <= 20 ? Color.orange : Color.white.opacity(0.8))
                            .accessibilityIdentifier("activity-battery")
                    }
                    Spacer(minLength: 2)
                    if let thermal = state.thermal {
                        Label(thermal.title, systemImage: "thermometer.medium")
                            .foregroundStyle(thermal == .hot || thermal == .critical ? Color.orange : Color.white.opacity(0.8))
                            .accessibilityIdentifier("activity-thermal")
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

    private var rowSpacing: CGFloat { family == .small ? 2 : 8 }
    private var highlightSize: CGFloat { family == .small ? 28 : 32 }
    private var showsHighlight: Bool {
        state.canSaveHighlight && !state.phase.isTerminal && !state.isDemo && !stale && highlightSessionID != nil
    }
    private var showsHighlightFeedback: Bool {
        state.highlightStatus != nil && !state.isDemo && !stale
    }
    private var highlightIndicator: some View {
        Image(systemName: highlightSymbol)
            .font(.system(size: family == .small ? 14 : 17, weight: .semibold))
            .foregroundStyle(highlightColor)
            .frame(width: highlightSize, height: highlightSize)
            .background(highlightColor.opacity(0.2), in: Circle())
            .contentShape(Circle())
    }
    private var highlightSymbol: String {
        switch state.highlightStatus {
        case .saving: "hourglass"
        case .saved: "checkmark"
        case .failed: "exclamationmark"
        case nil: "bolt.badge.clock"
        }
    }
    private var highlightColor: Color {
        switch state.highlightStatus {
        case .saved: .green
        case .failed: .orange
        default: .white
        }
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
