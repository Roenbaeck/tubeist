//
//  WatchRootView.swift
//  TubeistWatch Watch App
//

import SwiftUI

struct WatchRootView: View {
    @State private var client = WatchConnectivityClient.shared
    @State private var showStopConfirmation = false
    @State private var selectedPage = 0

    private var snapshot: WatchStateSnapshot { client.snapshot }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            TabView(selection: $selectedPage) {
                controls(at: timeline.date).tag(0)
                if snapshot.externalStatusConfigured {
                    WatchExternalStatusView(snapshot: snapshot, now: timeline.date).tag(1)
                }
            }
            .tabViewStyle(.page)
        }
        .onChange(of: snapshot.externalStatusConfigured) { _, configured in
            if !configured { selectedPage = 0 }
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

    private func controls(at now: Date) -> some View {
        ScrollView {
            VStack(spacing: 6) {
                WatchHealthBadge(snapshot: snapshot, now: now)
                if let startedAt = snapshot.startedAt {
                    if let stoppedAt = snapshot.stoppedAt {
                        Text(Duration.seconds(max(0, stoppedAt.timeIntervalSince(startedAt))),
                             format: .time(pattern: .hourMinuteSecond))
                            .monospacedDigit().font(.caption)
                    } else {
                        Text(startedAt, style: .timer).monospacedDigit().font(.caption)
                    }
                }
                startStopButton(at: now)
                if snapshot.canSaveHighlight {
                    WatchHighlightButton(status: snapshot.highlightStatus) { client.sendHighlight() }
                        .disabled(!client.isReachable || !snapshot.isFresh(at: now))
                }
                if !snapshot.isFresh(at: now) {
                    Text("Waiting for current iPhone status")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if !client.isReachable, snapshot.phase != .ended, snapshot.phase != .failed {
                    Label("iPhone not reachable", systemImage: "iphone.slash")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 12) // Keep the page indicator clear of the last button.
        }
    }

    @ViewBuilder
    private func startStopButton(at now: Date) -> some View {
        switch snapshot.phase {
        case .ended, .failed:
            // isReachable alone isn't enough: it can stay true for a
            // backgrounded-but-not-terminated phone app, but starting a
            // stream should require the app actually be in the foreground.
            if client.isReachable && snapshot.isAppActive && snapshot.isFresh(at: now) {
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
            .disabled(!client.isReachable || !snapshot.isFresh(at: now))
        }
    }
}

private struct WatchHealthBadge: View {
    let snapshot: WatchStateSnapshot
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(snapshot.phase.title).font(.headline)
        }
    }

    private var color: Color {
        switch snapshot.healthIndicator(at: now) {
        case .unknown: .gray
        case .untracked: .blue
        case .healthy: .green
        case .warning: .yellow
        case .problem: .red
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

struct WatchExternalStatusView: View {
    let snapshot: WatchStateSnapshot
    let now: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("External status").font(.headline)
                if let status = snapshot.externalStatus {
                    let current = status.isFresh(at: now) && snapshot.isFresh(at: now)
                    // Remote content is never parsed as Markdown, HTML, links,
                    // format strings, or commands.
                    Text(verbatim: status.text)
                        .font(.body)
                        .foregroundStyle(current ? .primary : .secondary)
                        .accessibilityIdentifier("external-status-text")
                    if !current {
                        Label("Out of date", systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(.yellow)
                    } else if snapshot.externalStatusRefreshFailed {
                        Text("Refresh failed; retrying…").foregroundStyle(.secondary)
                    }
                    Text("Received \(status.receivedAt, style: .relative) ago")
                        .foregroundStyle(.secondary)
                } else {
                    Text(snapshot.externalStatusRefreshFailed
                         ? "Status unavailable; retrying…" : "Waiting for external status…")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }
}

#Preview {
    WatchRootView()
}
