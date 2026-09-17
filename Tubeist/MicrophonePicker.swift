import SwiftUI

struct MicrophonePicker: View {
    let isDisabled: Bool
    let onError: (Error) -> Void
    @State private var inputs = AudioInputSnapshot()
    @State private var isChanging = false

    private var showsRouteStatus: Bool {
        guard let selected = inputs.selected else { return true }
        return !inputs.selectionIsAvailable || inputs.active.map(\.id) != [selected.id]
    }

    var body: some View {
        CaptureControlRow("Microphone") {
            VStack(alignment: .trailing, spacing: 4) {
                Menu {
                    Picker("Microphone", selection: Binding<String?>(
                        get: { inputs.selected?.id },
                        set: { select($0) }
                    )) {
                        Text("Automatic").tag(String?.none)
                        ForEach(inputs.available) { input in
                            Text(inputs.displayName(for: input)).tag(Optional(input.id))
                        }
                        if let selected = inputs.selected, !inputs.selectionIsAvailable {
                            Text("\(selected.name) (disconnected)")
                                .tag(Optional(selected.id))
                                .disabled(true)
                        }
                    }
                } label: {
                    CaptureMenuLabel(title: inputs.selected.map { inputs.displayName(for: $0) } ?? "Automatic")
                }
                .disabled(isChanging || isDisabled)
                .accessibilityLabel("Microphone Selection")
                .accessibilityValue(inputs.selected?.name ?? "Automatic")

                // An explicit input already names the active mic. Show extra
                // status only for automatic routing, fallback, or a pending change.
                if showsRouteStatus {
                    Text(inputs.status)
                        .font(.footnote)
                        .foregroundStyle(inputs.selectionIsAvailable ? .white.opacity(0.7) : .yellow)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                }
            }
        }
        .task { inputs = await AudioInputRouter.shared.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .tubeistAudioInputsChanged)
            .receive(on: DispatchQueue.main)) { _ in
            Task { inputs = await AudioInputRouter.shared.snapshot }
        }
    }

    private func select(_ id: String?) {
        guard !isChanging, !isDisabled, id != inputs.selected?.id else { return }
        isChanging = true
        Task {
            do {
                try await AudioInputRouter.shared.select(id: id)
            } catch {
                LOG("Could not change microphone: \(error.localizedDescription)", level: .error)
                onError(error)
            }
            inputs = await AudioInputRouter.shared.snapshot
            isChanging = false
        }
    }
}
