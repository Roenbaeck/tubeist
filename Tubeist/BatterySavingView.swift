import SwiftUI

struct BatterySavingView: View {
    @Environment(AppState.self) private var appState
    var onRestore: () -> Void
    var onBandwidthWarning: () -> Void
    var message: String?

    private var activity: String {
        switch appState.streamSessionState {
        case .idle: "Not streaming or recording"
        case .preparing: "Starting…"
        case .stopping: "Finishing uploads and recording…"
        case .failed: "Stream or recording stopped"
        case .live:
            Settings.stream
                ? (Settings.record ? "Streaming and recording" : "Streaming to YouTube")
                : "Recording"
        }
    }

    private var healthColor: Color {
        switch appState.streamHealth {
        case .pristine: .green
        case .degraded: .yellow
        case .unusable: .red
        case .silenced, .awaiting: .gray
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 18) {
                    Text("Battery saving mode")
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                    Text(activity)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .accessibilityIdentifier("battery-saving-activity")
                    if appState.isStreamSessionRunning, Settings.stream {
                        Text(appState.streamHealth.statusDescription)
                            .foregroundStyle(healthColor)
                        if let status = appState.youtubeStatus {
                            Text("YouTube: \(YouTubeBroadcast.label(for: status))")
                                .foregroundStyle(.gray)
                        }
                    }
                    SystemMetricsView(onBandwidthWarning: onBandwidthWarning)
                        .monospacedDigit()
                    if let message {
                        Text(message)
                            .foregroundStyle(.yellow)
                            .multilineTextAlignment(.center)
                    }
                    Button(action: onRestore) {
                        Label("Restore View", systemImage: "sunrise")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(.gray)
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityIdentifier("restore-battery-saving-view")
                    .accessibilityHint("Restores the preview, controls, and previous screen brightness")
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("battery-saving-screen")
    }
}
