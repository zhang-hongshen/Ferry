import AppKit
import StorageCore
import SwiftUI
import UniformTypeIdentifiers

/// The current directory as a grid of large icons, like Finder's icon view.
struct FileGridView: View {
    @Bindable var tab: BrowserTab
    let canPaste: Bool
    let perform: (ItemCommand, [RemoteItem]) -> Void

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(tab.displayedItems) { item in
                    FileGridCell(item: item, isSelected: tab.selection.contains(item.path), tab: tab)
                        .onTapGesture(count: 2) { open(item) }
                        .simultaneousGesture(TapGesture().onEnded { select(item) })
                        .onDrag { tab.dragProvider(for: item) ?? NSItemProvider() }
                        .contextMenu {
                            ItemContextMenu(tab: tab, items: menuItems(for: item), canPaste: canPaste,
                                            perform: perform)
                        }
                        .accessibilityAction(named: Text("Open")) { open(item) }
                }
            }
            .padding(12)
        }
        .contentShape(Rectangle())
        .onTapGesture { tab.selection = [] }
        .contextMenu {
            ItemContextMenu(tab: tab, items: [], canPaste: canPaste, perform: perform)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard tab.selection.count == 1 else { return .ignored }
            perform(.quickLook, tab.selectedItems)
            return .handled
        }
        .onKeyPress(.return) {
            guard tab.selection.count == 1 else { return .ignored }
            perform(.rename, tab.selectedItems)
            return .handled
        }
        .onDeleteCommand {
            perform(.delete, tab.selectedItems)
        }
        .onCopyCommand {
            commandProviders(.copy)
        }
        .onCutCommand {
            commandProviders(.cut)
        }
        .onPasteCommand(of: [.plainText]) { _ in
            perform(.paste, [])
        }
        .accessibilityIdentifier("fileGrid")
    }

    /// Command-click and Shift-click toggle an item; a plain click selects only it.
    private func select(_ item: RemoteItem) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            if tab.selection.remove(item.path) == nil {
                tab.selection.insert(item.path)
            }
        } else {
            tab.selection = [item.path]
        }
    }

    private func open(_ item: RemoteItem) {
        tab.selection = [item.path]
        perform(.open, [item])
    }

    /// Right-clicking a selected item acts on the whole selection.
    private func menuItems(for item: RemoteItem) -> [RemoteItem] {
        tab.selection.contains(item.path) ? tab.selectedItems : [item]
    }

    private func commandProviders(_ command: ItemCommand) -> [NSItemProvider] {
        let items = tab.selectedItems
        guard !items.isEmpty else { return [] }
        perform(command, items)
        return [NSItemProvider(object: items.map(\.path.string).joined(separator: "\n") as NSString)]
    }
}

/// One icon and its name, highlighted when selected.
private struct FileGridCell: View {
    let item: RemoteItem
    let isSelected: Bool
    let tab: BrowserTab

    var body: some View {
        let uploads = tab.uploads(at: item.path)
        VStack(spacing: 4) {
            FileIcon(item: item, size: 56)
                .uploadDimmed(item, uploads: uploads)
                .overlay(alignment: .bottomTrailing) {
                    UploadProgressView(jobs: uploads, isContainer: item.isContainer)
                }
                .padding(4)
                .background(isSelected ? Color.secondary.opacity(0.2) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
            if tab.renamingPath == item.path {
                InlineNameField(name: item.name, isContainer: item.isContainer) {
                    tab.commitRenaming(item, to: $0)
                } cancel: {
                    tab.cancelRenaming()
                }
                .multilineTextAlignment(.center)
            } else {
                name
                    .renameOnClick(item.path, in: tab)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: tab.renamingPath == item.path ? .contain : .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(UploadProgressView.status(of: uploads) ?? item.typeDescription)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var name: some View {
        Text(item.name)
            .font(.callout)
            .lineLimit(2)
            .truncationMode(.middle)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 4)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
    }
}
