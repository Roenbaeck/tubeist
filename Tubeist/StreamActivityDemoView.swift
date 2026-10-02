#if DEBUG
import SwiftUI
import ActivityKit
import WidgetKit

/// Launch with -live-activity-demo to exercise the real extension without camera,
/// credentials, a network connection or a public YouTube broadcast.
struct StreamActivityDemoView: View {
    static var isRequested: Bool { CommandLine.arguments.contains("-live-activity-demo") }
    @Environment(\.scenePhase) private var scenePhase
    @State private var activityStatus = "Not started"
    @State private var controller = StreamActivityController()
    @State private var ready = false
    @State private var busy = false
    @State private var stale = false
    @State private var previewHighlights = false
    @State private var previewHighlightStatus: HighlightStatus?
    @State private var previewSessionID = UUID()
    @State private var smallWatch = false
    @State private var message = "No stream or recording is created."
    @State private var state = StreamActivityAttributes.ContentState(
        phase: .streaming, startedAt: Date().addingTimeInterval(-83), stoppedAt: nil,
        health: .good, healthTracked: true, link: .good, viewers: 142, bitrateKbps: 12800,
        batteryPercent: 72, thermal: .normal, fullDetail: true, isDemo: true)

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Live Activity simulator").font(.title2.bold())
                Text(message).font(.caption).foregroundStyle(.secondary)
                Text("ActivityKit: \(activityStatus)").font(.caption.monospaced())
                HStack {
                    Button("Healthy") { change(phase: .streaming, problem: false) }
                    Button("Problem") { change(phase: .streaming, problem: true) }
                    Button("Finishing") { change(phase: .finishing, problem: false) }
                    Button("Ended") { change(phase: .ended, problem: false) }
                }
                .buttonStyle(.bordered)
                HStack {
                    Toggle("Full detail", isOn: $state.fullDetail)
                    Toggle("Stale preview", isOn: $stale)
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .frame(maxWidth: 430)
                if CommandLine.arguments.contains("-highlight-layout-preview") {
                    HStack {
                        Toggle("Highlights", isOn: $previewHighlights)
                        Toggle("Small Watch", isOn: $smallWatch)
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.bordered)
                    HStack {
                        Button("Ready") { previewHighlightStatus = nil }
                        Button("Saving") { previewHighlightStatus = .saving }
                        Button("Saved") { previewHighlightStatus = .saved }
                        Button("Failed") { previewHighlightStatus = .failed }
                    }
                    .buttonStyle(.bordered)
                }
                HStack {
                    Button("New session") {
                        busy = true
                        Task {
                            await controller.begin(sessionID: UUID())
                            state.startedAt = Date()
                            state.stoppedAt = nil
                            state.phase = .streaming
                            await controller.publish(state, alert: nil, now: Date())
                            busy = false
                        }
                    }
                    Button("Send test alert") {
                        busy = true
                        Task {
                            if await StreamActivityNotifications.requestPermission() {
                                await controller.publish(state, alert: .test, now: Date())
                                message = "Test alert sent; check the paired Watch."
                            } else {
                                message = "Notifications are disabled in iPhone Settings."
                            }
                            busy = false
                        }
                    }
                }
                .buttonStyle(.bordered)
                Text("Lock the simulator to inspect the actual Live Activity. Dismiss it, then change a state: it should stay dismissed until New session.")
                    .font(.caption).frame(maxWidth: 430)
            }
            VStack {
                Text("Apple Watch layout").font(.caption)
                StreamActivityCard(state: watchPreviewState, stale: stale, highlightSessionID: previewSessionID)
                    .environment(\.activityFamily, .small)
                    .frame(width: smallWatch ? 152 : 191, height: smallWatch ? 69.5 : 81.5)
                    .background(.black, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("watch-activity-preview")
            }
        }
        .padding(20)
        .disabled(!ready || busy)
        .onChange(of: state.fullDetail) { _, _ in
            Task { await controller.publish(state, alert: nil, now: Date()) }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, !ready else { return }
            await controller.begin(sessionID: UUID())
            await controller.publish(state, alert: nil, now: Date())
            activityStatus = Activity<StreamActivityAttributes>.activities.first.map { String(describing: $0.activityState) } ?? "unavailable"
            ready = true
        }
    }

    // Only the on-screen fixture offers an action; the published demo activity
    // remains marked isDemo and cannot send a highlight request.
    private var watchPreviewState: StreamActivityAttributes.ContentState {
        guard CommandLine.arguments.contains("-highlight-layout-preview") else { return state }
        var preview = state
        preview.isDemo = false
        preview.canSaveHighlight = previewHighlights && (state.phase == .streaming || state.phase == .recording)
        preview.highlightStatus = previewHighlightStatus
        // Exercise a longer elapsed time without waiting for a real session.
        preview.startedAt = state.startedAt?.addingTimeInterval(-3600)
        return preview
    }

    private func change(phase: StreamActivityPhase, problem: Bool) {
        busy = true
        state.phase = phase
        state.health = problem ? .error : .good
        state.link = problem ? .degraded : .good
        state.stoppedAt = phase == .finishing || phase.isTerminal ? Date() : nil
        Task {
            await controller.publish(state, alert: nil, now: Date())
            if phase.isTerminal { await controller.finish(state, now: Date()) }
            busy = false
        }
    }
}
#endif
