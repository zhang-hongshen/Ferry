import SwiftUI

@main
struct FerryApp: App {
    @AppStorage(SettingsKey.theme) private var theme: AppTheme = .system
    @AppStorage(SettingsKey.language) private var languageCode = AppLanguage.initialSelection.rawValue

    @State private var store: ConnectionStore
    @State private var pool: ConnectionPool
    @State private var transfers: TransferQueue
    @State private var clipboard = RemoteClipboard()
    @State private var editor = RemoteFileEditor()

    init() {
        SettingsKey.registerDefaults()
        let store = ConnectionStore()
        let pool = ConnectionPool()
        _store = State(initialValue: store)
        _pool = State(initialValue: pool)
        _transfers = State(initialValue: TransferQueue(store: store, pool: pool))
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    var body: some Scene {
        WindowGroup {
            MainWindow(pool: pool, transfers: transfers)
                .appEnvironment(store: store, pool: pool, transfers: transfers, clipboard: clipboard, editor: editor)
                .environment(\.locale, language.locale)
                .preferredColorScheme(theme.colorScheme)
        }
        .commands {
            FerryCommands(store: store)
        }

        Settings {
            SettingsView()
                .environment(\.locale, language.locale)
                .preferredColorScheme(theme.colorScheme)
        }
    }
}

extension View {
    func appEnvironment(store: ConnectionStore, pool: ConnectionPool, transfers: TransferQueue,
                        clipboard: RemoteClipboard, editor: RemoteFileEditor) -> some View {
        environment(store)
            .environment(pool)
            .environment(transfers)
            .environment(clipboard)
            .environment(editor)
    }
}
