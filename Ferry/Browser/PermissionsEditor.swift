import StorageCore
import SwiftUI

/// Edits POSIX permissions (chmod) as a read/write/execute grid with the octal value.
struct PermissionsEditor: View {
    let items: [RemoteItem]
    let apply: (UInt16) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var permissions: UInt16

    private static let classes: [LocalizedStringKey] = ["Owner", "Group", "Everyone"]
    private static let rights: [LocalizedStringKey] = ["Read", "Write", "Execute"]

    init(items: [RemoteItem], apply: @escaping (UInt16) -> Void) {
        self.items = items
        self.apply = apply
        _permissions = State(initialValue: items.first?.permissions ?? 0o644)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(items.count == 1 ? items[0].name : String(localized: "\(items.count) items"))
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    ForEach(0..<3, id: \.self) { right in
                        Text(Self.rights[right])
                    }
                }
                ForEach(0..<3, id: \.self) { group in
                    GridRow {
                        Text(Self.classes[group])
                        ForEach(0..<3, id: \.self) { right in
                            Toggle(isOn: binding(group: group, right: right)) {
                                Text(Self.rights[right])
                            }
                            .labelsHidden()
                            .accessibilityLabel(Text("\(Text(Self.classes[group])) \(Text(Self.rights[right]))"))
                        }
                    }
                }
            }
            LabeledContent("Octal") {
                Text(String(permissions, radix: 8).leftPadded(to: 3))
                    .font(.body.monospaced())
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    apply(permissions)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func binding(group: Int, right: Int) -> Binding<Bool> {
        let mask = UInt16(1) << UInt16(8 - (group * 3 + right))
        return Binding {
            permissions & mask != 0
        } set: { isOn in
            if isOn {
                permissions |= mask
            } else {
                permissions &= ~mask
            }
        }
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        String(repeating: "0", count: max(0, length - count)) + self
    }
}
