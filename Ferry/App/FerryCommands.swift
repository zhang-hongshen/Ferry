import SwiftUI

extension FocusedValues {
    @Entry var browserWindow: BrowserWindowModel?
    @Entry var connectionSheet: Binding<ConnectionEditorRequest?>?
    @Entry var connectionFileAction: Binding<ConnectionFileAction?>?
}

/// Menu commands and keyboard shortcuts. Commands act on the focused window's current tab.
struct FerryCommands: Commands {
    let store: ConnectionStore

    @FocusedValue(\.browserWindow) private var window
    @FocusedValue(\.connectionSheet) private var connectionSheet
    @FocusedValue(\.connectionFileAction) private var connectionFileAction
    @AppStorage("browserViewMode") private var viewMode = BrowserViewMode.list
    @AppStorage("showsInspector") private var showsInspector = false

    private var tab: BrowserTab? { window?.currentTab }
    private var hasConnection: Bool { tab?.provider != nil }
    private var hasSelection: Bool { tab?.selection.isEmpty == false }

    private func viewModeBinding(_ mode: BrowserViewMode) -> Binding<Bool> {
        Binding {
            viewMode == mode
        } set: { isOn in
            if isOn {
                viewMode = mode
            }
        }
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                window?.newTab()
            }
            .keyboardShortcut("t")
            .disabled(window == nil)

            Button("New Connection…") {
                connectionSheet?.wrappedValue = .new
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(connectionSheet == nil)

            Divider()

            Button("Open") {
                tab?.pendingAction = .open
            }
            .keyboardShortcut("o")
            .disabled(tab?.selection.count != 1)

            Button("New Folder") {
                tab?.pendingAction = .newFolder
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(tab?.canWriteHere != true)

            Button("Upload…") {
                tab?.pendingAction = .upload
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(tab?.canWriteHere != true)

            Button("Download…") {
                tab?.pendingAction = .download
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(tab?.selection.isEmpty != false)

            Button("Quick Look") {
                tab?.pendingAction = .quickLook
            }
            .keyboardShortcut("y")
            .disabled(tab?.selection.count != 1)

            Button("Rename") {
                tab?.pendingAction = .rename
            }
            .disabled(tab?.selection.count != 1)

            Button("Delete") {
                tab?.pendingAction = .delete
            }
            .keyboardShortcut(.delete)
            .disabled(tab?.selection.isEmpty != false)

            Divider()

            Button("Import Connections…") {
                connectionFileAction?.wrappedValue = .import
            }
            .disabled(connectionFileAction == nil)

            Button("Export Connections…") {
                connectionFileAction?.wrappedValue = .export
            }
            .disabled(connectionFileAction == nil || store.profiles.isEmpty)
        }

        CommandGroup(before: .sidebar) {
            Toggle("as Icons", isOn: viewModeBinding(.icons))
                .keyboardShortcut("1")
            Toggle("as List", isOn: viewModeBinding(.list))
                .keyboardShortcut("2")
            Toggle("as Columns", isOn: viewModeBinding(.columns))
                .keyboardShortcut("3")

            Divider()

            Button("Refresh") {
                tab?.refresh()
            }
            .keyboardShortcut("r")
            .disabled(!hasConnection)

            Divider()
        }

        CommandGroup(after: .sidebar) {
            Button(showsInspector && hasSelection ? "Hide Inspector" : "Show Inspector") {
                showsInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(!hasSelection)
        }

        CommandMenu("Go") {
            Button("Back") {
                tab?.goBack()
            }
            .keyboardShortcut("[")
            .disabled(tab?.canGoBack != true)

            Button("Forward") {
                tab?.goForward()
            }
            .keyboardShortcut("]")
            .disabled(tab?.canGoForward != true)

            Button("Enclosing Folder") {
                tab?.goUp()
            }
            .keyboardShortcut(.upArrow)
            .disabled(tab?.canGoUp != true)
        }
    }
}
