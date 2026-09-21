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
                StreamActivityView(state: state, stale: stale)
                    .environment(\.activityFamily, .small)
                    .padding(10).frame(width: 160, height: 140)
                    .background(.black, in: RoundedRectangle(cornerRadius: 18))
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
