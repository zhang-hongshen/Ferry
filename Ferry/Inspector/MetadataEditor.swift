import StorageCore
import SwiftUI

/// S3 object metadata: system headers and custom `x-amz-meta-*` entries, saved by replacing
/// the object's metadata.
struct MetadataEditor: View {
    let tab: BrowserTab
    let item: RemoteItem

    @State private var original: RemoteMetadata?
    @State private var draft = RemoteMetadata()
    @State private var customEntries: [CustomEntry] = []
    @State private var isSaving = false
    @State private var error: String?

    struct CustomEntry: Identifiable, Hashable {
        let id = UUID()
        var key: String
        var value: String
    }

    var body: some View {
        Section("Metadata") {
            if original == nil, error == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                if let eTag = draft.eTag {
                    LabeledContent("ETag") {
                        Text(eTag)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
                if let storageClass = draft.storageClass {
                    LabeledContent("Storage Class", value: storageClass)
                }
                TextField("Content-Type", text: text(\.contentType))
                TextField("Cache-Control", text: text(\.cacheControl))
                TextField("Content-Disposition", text: text(\.contentDisposition))
                TextField("Content-Encoding", text: text(\.contentEncoding))
            }
            if let error {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        .task { await load() }
        if original != nil {
            Section("Custom Metadata") {
                ForEach($customEntries) { $entry in
                    HStack {
                        TextField("Key", text: $entry.key)
                            .labelsHidden()
                        TextField("Value", text: $entry.value)
                            .labelsHidden()
                        Button {
                            customEntries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Remove \(entry.key)"))
                    }
                }
                Button {
                    customEntries.append(CustomEntry(key: "", value: ""))
                } label: {
                    Label("Add Metadata", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            Section {
                HStack {
                    Spacer()
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Revert") { reset(to: original) }
                        .disabled(!hasChanges || isSaving)
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!hasChanges || isSaving)
                }
            }
        }
    }

    private var edited: RemoteMetadata {
        var metadata = draft
        metadata.custom = Dictionary(
            customEntries.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }.map { ($0.key, $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        return metadata
    }

    private var hasChanges: Bool {
        original != nil && edited != original
    }

    private func text(_ keyPath: WritableKeyPath<RemoteMetadata, String?>) -> Binding<String> {
        Binding {
            draft[keyPath: keyPath] ?? ""
        } set: { value in
            draft[keyPath: keyPath] = value.isEmpty ? nil : value
        }
    }

    private func reset(to metadata: RemoteMetadata?) {
        guard let metadata else { return }
        draft = metadata
        customEntries = metadata.custom.sorted { $0.key < $1.key }.map { CustomEntry(key: $0.key, value: $0.value) }
    }

    private func load() async {
        guard let provider = tab.provider else { return }
        do {
            let metadata = try await provider.metadata(for: item.path)
            original = metadata
            reset(to: metadata)
        } catch {
            self.error = PresentableError(error).message
        }
    }

    private func save() {
        guard let provider = tab.provider else { return }
        let metadata = edited
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                try await provider.updateMetadata(metadata, for: item.path)
                let reloaded = try await provider.metadata(for: item.path)
                original = reloaded
                reset(to: reloaded)
            } catch {
                self.error = PresentableError(error).message
            }
        }
    }
}
