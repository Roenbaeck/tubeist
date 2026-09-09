import SwiftUI

struct OverlayOrderView: View {
    @Binding var overlays: [OverlaySetting]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(overlays) { overlay in
                        Text(overlay.url)
                            .accessibilityIdentifier("overlay-order-\(overlay.id)")
                    }
                    .onMove { offsets, destination in
                        overlays.move(fromOffsets: offsets, toOffset: destination)
                    }
                } footer: {
                    Text("Drag the handles to change the order. The top row appears in front. Save Settings to apply your changes.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Overlay Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
