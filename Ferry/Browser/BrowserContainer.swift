import StorageCore
import SwiftUI

/// The tab strip (when there is more than one tab) above the current tab's browser.
struct BrowserContainer: View {
    let model: BrowserWindowModel
    @Binding var editorRequest: ConnectionEditorRequest?

    var body: some View {
        VStack(spacing: 0) {
            if model.tabs.count > 1 {
                TabStrip(model: model)
                Divider()
            }
            if let tab = model.currentTab, tab.profile != nil {
                BrowserView(tab: tab, model: model, editorRequest: $editorRequest)
                    .id(tab.id)
            } else {
                ContentUnavailableView("No Connection Selected", systemImage: "externaldrive")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct TabStrip: View {
    let model: BrowserWindowModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(model.tabs) { tab in
                TabStripItem(tab: tab, isSelected: tab.id == model.currentTab?.id) {
                    model.selectedTabID = tab.id
                } close: {
                    model.close(tab)
                }
                Divider()
            }
            Button {
                model.newTab()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("New Tab")
        }
        .frame(height: 28)
        .background(.bar)
    }
}

private struct TabStripItem: View {
    let tab: BrowserTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Button(action: select) {
                Label(tab.title, systemImage: tab.profile?.kind.systemImage ?? "square.dashed")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            HStack {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .opacity(isHovering || isSelected ? 1 : 0)
                .accessibilityLabel("Close Tab")
                Spacer()
            }
            .padding(.leading, 6)
        }
        .frame(maxWidth: 240)
        .background(isSelected ? Color(nsColor: .controlBackgroundColor) : .clear)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .onHover { isHovering = $0 }
    }
}

/// Clickable breadcrumbs from the tab's top path (the connection root or the bucket) to the current directory.
struct PathBar: View {
    let tab: BrowserTab

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let top = tab.topPath
                ForEach(Array(tab.path.ancestors.dropFirst(top.components.count).enumerated()), id: \.offset) { index, path in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    Button {
                        tab.navigate(to: path)
                    } label: {
                        if path.isRoot {
                            Label(tab.profile?.displayName ?? "/", systemImage: tab.profile?.kind.systemImage ?? "folder")
                        } else if path == top {
                            Label(path.name, systemImage: "archivebox")
                        } else {
                            Label {
                                Text(path.name)
                            } icon: {
                                FileIcon(item: RemoteItem(path: path, kind: .directory))
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(path == tab.path ? .primary : .secondary)
                    .accessibilityAddTraits(path == tab.path ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 28)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }
}
