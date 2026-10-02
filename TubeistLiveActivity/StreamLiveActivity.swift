import ActivityKit
import SwiftUI
import WidgetKit

struct StreamLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StreamActivityAttributes.self) { context in
            StreamActivityCard(state: context.state, stale: context.isStale, highlightSessionID: context.attributes.sessionID)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StreamActivityBadge(state: context.state, stale: context.isStale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StreamActivityTimer(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StreamActivityView(state: context.state, stale: context.isStale, highlightSessionID: context.attributes.sessionID)
                }
            } compactLeading: {
                Image(systemName: context.state.phase == .recording ? "record.circle" : "dot.radiowaves.left.and.right")
                    .foregroundStyle(StreamActivityAppearance.color(context.state, stale: context.isStale))
                    .accessibilityLabel(context.isStale ? "Status unavailable" : context.state.phase.title)
            } compactTrailing: {
                StreamActivityTimer(state: context.state).frame(maxWidth: 56)
            } minimal: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(StreamActivityAppearance.color(context.state, stale: context.isStale))
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

#if DEBUG
extension StreamActivityAttributes {
    static var preview: Self { .init(sessionID: UUID()) }
    static func previewState(phase: StreamActivityPhase = .streaming, health: StreamActivityHealth = .good,
                             full: Bool = true) -> ContentState {
        .init(phase: phase, startedAt: Date().addingTimeInterval(-3723),
              stoppedAt: phase == .finishing || phase.isTerminal ? Date() : nil,
              health: health, healthTracked: true, link: health == .error ? .failed : .good,
              viewers: 142, bitrateKbps: 12800, batteryPercent: 72, thermal: .normal, fullDetail: full)
    }
}

#Preview("Stream states", as: .content, using: StreamActivityAttributes.preview) {
    StreamLiveActivity()
} contentStates: {
    StreamActivityAttributes.previewState(full: false)
    StreamActivityAttributes.previewState()
    StreamActivityAttributes.previewState(health: .error)
    StreamActivityAttributes.previewState(phase: .finishing)
    StreamActivityAttributes.previewState(phase: .ended)
}

#Preview("Watch: stale status") {
    StreamActivityCard(state: StreamActivityAttributes.previewState(), stale: true)
        .environment(\.activityFamily, .small)
        .frame(width: 152, height: 69.5).background(.black)
}

#Preview("Watch: highlights, smallest card") {
    let state = {
        var state = StreamActivityAttributes.previewState()
        state.canSaveHighlight = true
        return state
    }()
    StreamActivityCard(state: state, stale: false, highlightSessionID: UUID())
        .environment(\.activityFamily, .small)
        .frame(width: 152, height: 69.5).background(.black)
}
#endif
