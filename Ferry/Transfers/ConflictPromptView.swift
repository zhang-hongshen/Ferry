import SwiftUI

/// Asks whether to replace, skip, or keep both when a name already exists at the destination.
struct ConflictPromptView: View {
    let prompt: ConflictResolver.Prompt
    let resolver: ConflictResolver
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("“\(prompt.name)” already exists.")
                    .font(.headline)
            } icon: {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.orange)
            }
            if prompt.remaining > 0 {
                Toggle("Apply to All (\(prompt.remaining + 1))", isOn: $applyToAll)
            }
            HStack {
                Button("Skip") { answer(.skip) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Keep Both") { answer(.keepBoth) }
                Button("Replace") { answer(.replace) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .interactiveDismissDisabled()
    }

    private func answer(_ resolution: ConflictResolution) {
        resolver.answer(resolution, applyToAll: applyToAll)
    }
}
