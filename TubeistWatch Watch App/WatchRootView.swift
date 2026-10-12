//
//  WatchRootView.swift
//  TubeistWatch Watch App
//

import SwiftUI

struct WatchRootView: View {
    @State private var client = WatchConnectivityClient.shared
    @State private var showStopConfirmation = false

    private var snapshot: WatchStateSnapshot { client.snapshot }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                WatchHealthBadge(snapshot: snapshot)
                if let startedAt = snapshot.startedAt {
                    Text(startedAt, style: .timer)
                        .monospacedDigit()
                        .font(.caption)
                }
                if snapshot.scoreboardConfigured {
                    WatchScoreView(score: snapshot.scoreboard)
                }
                startStopButton
                if snapshot.canSaveHighlight {
                    WatchHighlightButton(status: snapshot.highlightStatus) {
                        client.sendHighlight()
                    }
                }
                // While idle, startStopButton already shows "App not ready" in
                // place of the Start button, so this stays only for the case
                // where reachability drops mid-stream.
                if !client.isReachable, snapshot.phase != .ended, snapshot.phase != .failed {
                    Label("iPhone not reachable", systemImage: "iphone.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
        .onAppear { client.start() }
        .alert(
            "Couldn't complete the action",
            isPresented: Binding(
                get: { client.lastErrorMessage != nil },
                set: { if !$0 { client.lastErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(client.lastErrorMessage ?? "")
        }
        .confirmationDialog(
            "Stop streaming?",
            isPresented: $showStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop Streaming", role: .destructive) { client.sendStop() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var startStopButton: some View {
        switch snapshot.phase {
        case .ended, .failed:
            // isReachable alone isn't enough: it can stay true for a
            // backgrounded-but-not-terminated phone app, but starting a
            // stream should require the app actually be in the foreground.
            if client.isReachable && snapshot.isAppActive {
                Button {
                    client.sendStart()
                } label: {
                    Label("Start", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
            } else {
                Label("App not ready", systemImage: "iphone.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .preparing, .streaming, .recording, .finishing:
            // Stop ends a live broadcast, so it asks for confirmation rather
            // than acting on a single tap the way Start does.
            Button(role: .destructive) {
                showStopConfirmation = true
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct WatchHealthBadge: View {
    let snapshot: WatchStateSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(snapshot.phase.title).font(.headline)
        }
    }

    private var color: Color {
        guard snapshot.phase == .streaming || snapshot.phase == .recording else { return .gray }
        guard snapshot.healthTracked else { return .blue }
        switch snapshot.health {
        case .good: return .green
        case .warning: return .yellow
        case .error: return .red
        case .waiting, .unknown: return .gray
        }
    }
}

private struct WatchHighlightButton: View {
    let status: HighlightStatus?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Label("Highlight", systemImage: "bolt.badge.clock")
                if let status {
                    Text(status.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .tint(.yellow)
        .disabled(status == .saving)
    }
}

private struct WatchScoreView: View {
    let score: WatchScoreSnapshot?

    var body: some View {
        if let score {
            VStack(spacing: 2) {
                Text("\(score.teamA) \(score.setsA) – \(score.setsB) \(score.teamB)")
                    .font(.caption)
                Text("\(score.pointsA) – \(score.pointsB)")
                    .font(.title3).monospacedDigit()
            }
        } else {
            Text("Waiting for score…")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    WatchRootView()
}
