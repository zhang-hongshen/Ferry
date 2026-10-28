import StorageCore
import SwiftUI
import UniformTypeIdentifiers

enum ConnectionEditorRequest: Identifiable, Hashable {
    case new
    case edit(ConnectionProfile)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let profile): profile.id.uuidString
        }
    }
}

enum ConnectionFileAction: Hashable {
    case `import`
    case export
}

/// Sidebar of connections, the tabbed browser, and the inspector.
struct MainWindow: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(ConnectionPool.self) private var pool
    @Environment(TransferQueue.self) private var transfers
    @State private var model: BrowserWindowModel
    @State private var editorRequest: ConnectionEditorRequest?
    @State private var fileAction: ConnectionFileAction?
    @State private var fileError: PresentableError?
    @AppStorage("showsInspector") private var showsInspector = false

    init(pool: ConnectionPool, transfers: TransferQueue) {
        _model = State(initialValue: BrowserWindowModel(pool: pool, transfers: transfers))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, editorRequest: $editorRequest)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            BrowserContainer(model: model, editorRequest: $editorRequest)
                .inspector(isPresented: isInspectorPresented) {
                    InspectorView(tab: model.currentTab)
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 420)
                }
        }
        .frame(minWidth: 760, minHeight: 420)
        .focusedSceneValue(\.browserWindow, model)
        .focusedSceneValue(\.connectionSheet, $editorRequest)
        .focusedSceneValue(\.connectionFileAction, $fileAction)
        .sheet(item: $editorRequest) { request in
            ConnectionEditorView(request: request) { saved in
                pool.invalidate(saved.id)
                model.profileDidChange(saved)
            }
        }
        .sheet(item: Binding(get: { pool.knownHosts.prompt }, set: { _ in })) { prompt in
            HostKeyPromptView(key: prompt.key, knownHosts: pool.knownHosts)
        }
        .sheet(item: Binding(get: { model.conflicts.prompt }, set: { _ in })) { prompt in
            ConflictPromptView(prompt: prompt, resolver: model.conflicts)
        }
        .fileImporter(isPresented: isPresenting(.import), allowedContentTypes: [.json]) { result in
            importConnections(result)
        }
        .fileExporter(isPresented: isPresenting(.export), document: exportDocument,
                      contentType: .json, defaultFilename: "Ferry Connections") { result in
            if case .failure(let error) = result {
                fileError = PresentableError(error)
            }
        }
        .alert(fileError?.title ?? "", isPresented: $fileError.isPresent(),
               presenting: fileError) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.message)
        }
        .alert(transfers.downloadError?.title ?? "", isPresented: downloadErrorPresented,
               presenting: transfers.downloadError) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.message)
        }
    }

    /// The inspector follows the user's choice but stays hidden while nothing is selected.
    private var isInspectorPresented: Binding<Bool> {
        Binding {
            showsInspector && model.currentTab?.selection.isEmpty == false
        } set: { isPresented in
            showsInspector = isPresented
        }
    }

    private var downloadErrorPresented: Binding<Bool> {
        Binding {
            transfers.downloadError != nil
        } set: { isPresented in
            if !isPresented { transfers.downloadError = nil }
        }
    }

    private var exportDocument: ConnectionsDocument? {
        guard fileAction == .export else { return nil }
        return try? ConnectionsDocument(data: store.exportData())
    }

    private func isPresenting(_ action: ConnectionFileAction) -> Binding<Bool> {
        Binding(get: { fileAction == action }, set: { if !$0 { fileAction = nil } })
    }

    private func importConnections(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            try store.importProfiles(from: url)
        } catch {
            fileError = PresentableError(error)
        }
    }
}

/// Exports all connections as JSON without secrets.
struct ConnectionsDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
