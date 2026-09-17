import SwiftUI

struct CaptureControlsPanel: View {
    let cameras: [String]
    @Binding var selectedCamera: String
    @Binding var selectedMonitor: Monitor
    let isDisabled: Bool
    let onError: (Error) -> Void

    var body: some View {
        CapturePanel {
            CaptureControlRow("Camera") {
                Menu {
                    Picker("Camera", selection: $selectedCamera) {
                        ForEach(cameras, id: \.self) { camera in
                            Text(camera).tag(camera)
                        }
                    }
                } label: {
                    CaptureMenuLabel(title: selectedCamera)
                }
                .disabled(isDisabled)
                .accessibilityLabel("Camera Selection")
                .accessibilityValue(selectedCamera)
            }
            Divider().overlay(.white.opacity(0.15))
            MicrophonePicker(isDisabled: isDisabled, onError: onError)
            Divider().overlay(.white.opacity(0.15))
            CaptureControlRow("Monitor") {
                Menu {
                    Picker("Monitor", selection: $selectedMonitor) {
                        Text("Input").tag(Monitor.camera)
                        Text("Output").tag(Monitor.output)
                    }
                } label: {
                    CaptureMenuLabel(title: selectedMonitor == .camera ? "Input" : "Output")
                }
                .accessibilityLabel("Monitor Selection")
                .accessibilityValue(selectedMonitor == .camera ? "Input" : "Output")
                .accessibilityHint("Input shows the camera preview. Output shows the processed video.")
            }
        }
    }
}

struct StabilizationControlsPanel: View {
    let modes: [String]
    @Binding var selectedMode: String
    @Binding var showHorizonLevel: Bool

    var body: some View {
        CapturePanel {
            CaptureChoiceRow("Stabilization", selection: $selectedMode, choices: modes)
                .accessibilityIdentifier("stabilization-selection")
            Divider().overlay(.white.opacity(0.15))
            Toggle("Horizon level", isOn: $showHorizonLevel)
                .tint(.green)
                .foregroundStyle(.white.opacity(0.85))
                .frame(minHeight: 52)
                .accessibilityIdentifier("horizon-level-toggle")
        }
    }
}

struct StylingControlsPanel: View {
    @Binding var style: String
    @Binding var effect: String

    var body: some View {
        CapturePanel {
            CaptureChoiceRow("Style", selection: $style, choices: AVAILABLE_STYLES)
            Divider().overlay(.white.opacity(0.15))
            CaptureChoiceRow("Effect", selection: $effect, choices: AVAILABLE_EFFECTS)
        }
    }
}

struct CaptureChoiceRow: View {
    let title: String
    @Binding var selection: String
    let choices: [String]

    init(_ title: String, selection: Binding<String>, choices: [String]) {
        self.title = title
        self._selection = selection
        self.choices = choices
    }

    var body: some View {
        CaptureControlRow(title) {
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                CaptureMenuLabel(title: selection)
            }
            .accessibilityLabel("\(title) Selection")
            .accessibilityValue(selection)
        }
    }
}

struct CapturePanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }
}

struct CaptureControlRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @ScaledMetric(relativeTo: .body) private var labelWidth = 104.0

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: labelWidth, height: 44, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

struct CaptureMenuLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.tint)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
