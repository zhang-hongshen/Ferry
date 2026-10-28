import AppKit
import StorageCore
import SwiftUI

/// Edits a name in place, like Finder: the name without its extension starts selected, Return or
/// clicking elsewhere commits, and Escape cancels.
struct InlineNameField: View {
    let name: String
    let isContainer: Bool
    let commit: (String) -> Void
    let cancel: () -> Void

    @State private var text: String
    @State private var textSelection: TextSelection?
    @State private var isCancelled = false
    @FocusState private var isFocused: Bool

    init(name: String, isContainer: Bool, commit: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.name = name
        self.isContainer = isContainer
        self.commit = commit
        self.cancel = cancel
        _text = State(initialValue: name)
    }

    var body: some View {
        TextField("Name", text: $text, selection: $textSelection)
            .labelsHidden()
            .textFieldStyle(.squareBorder)
            .focused($isFocused)
            .onSubmit { commit(text) }
            .onExitCommand {
                isCancelled = true
                cancel()
            }
            .onChange(of: isFocused) { _, focused in
                if !focused, !isCancelled {
                    commit(text)
                }
            }
            .onAppear {
                isFocused = true
                textSelection = TextSelection(range: text.startIndex..<baseNameEnd)
            }
            .accessibilityLabel("Name")
    }

    /// The end of the name before its extension; folders and dotfiles select the whole name.
    private var baseNameEnd: String.Index {
        guard !isContainer, let dot = text.lastIndex(of: "."), dot != text.startIndex else { return text.endIndex }
        return dot
    }
}

extension View {
    /// Marks this view as the item's name, so clicking it while the item is the only selection renames it.
    func renameOnClick(_ path: RemotePath, in tab: BrowserTab) -> some View {
        onHover { isInside in
            if isInside {
                tab.hoveredNamePath = path
            } else if tab.hoveredNamePath == path {
                tab.hoveredNamePath = nil
            }
        }
    }

    /// Reports plain clicks on a name marked with `renameOnClick` to the tab. The views keep handling the
    /// clicks themselves; the monitor only observes them.
    func nameClickMonitor(for tab: BrowserTab) -> some View {
        modifier(NameClickMonitor(tab: tab))
    }
}

private struct NameClickMonitor: ViewModifier {
    let tab: BrowserTab
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [tab] event in
                    MainActor.assumeIsolated {
                        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        if let path = tab.hoveredNamePath,
                           modifiers.isDisjoint(with: [.command, .shift, .option, .control]) {
                            tab.nameClicked(path, clickCount: event.clickCount)
                        }
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
                monitor = nil
                tab.hoveredNamePath = nil
                tab.cancelRenameOnClick()
            }
    }
}
