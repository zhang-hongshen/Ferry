import StorageCore
import SwiftUI
import UniformTypeIdentifiers

/// Adds or edits a connection. A new connection starts by choosing its protocol; the form then
/// shows that protocol's settings.
struct ConnectionEditorView: View {
    let request: ConnectionEditorRequest
    let didSave: (ConnectionProfile) -> Void

    @Environment(ConnectionStore.self) private var store
    @Environment(ConnectionPool.self) private var pool
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ConnectionProfile?
    @State private var secrets = ConnectionSecrets()
    @State private var test = TestState.idle
    @State private var error: String?
    @State private var showsKeyImporter = false

    enum TestState: Equatable {
        case idle
        case testing
        case succeeded
        case failed(String)
    }

    var body: some View {
        Group {
            if let profile = Binding($profile) {
                form(profile)
            } else {
                ProtocolPicker { kind in
                    profile = ConnectionProfile(kind: kind)
                }
            }
        }
        .frame(width: 480)
        .onAppear(perform: loadRequest)
    }

    // MARK: Form

    private func form(_ profile: Binding<ConnectionProfile>) -> some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Protocol") {
                        Label(profile.wrappedValue.kind.title, systemImage: profile.wrappedValue.kind.systemImage)
                    }
                    TextField("Name", text: profile.name, prompt: Text(profile.wrappedValue.displayName))
                    GroupField(group: profile.group, groups: store.namedGroups)
                }
                Section {
                    switch profile.wrappedValue.kind {
                    case .s3: s3Fields(profile.s3)
                    case .sftp: sftpFields(profile.sftp)
                    case .ftp: ftpFields(profile.ftp)
                    case .webDAV: webDAVFields(profile.webDAV)
                    case .smb: smbFields(profile.smb)
                    }
                }
                Section {
                    TextField("Initial Path", text: profile.initialPath, prompt: Text(verbatim: "/"))
                }
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .onChange(of: profile.wrappedValue) { test = .idle }
            .onChange(of: secrets) { test = .idle }

            Divider()
            HStack {
                Button("Test Connection", action: testConnection)
                    .disabled(test == .testing)
                testStatus
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .fileImporter(isPresented: $showsKeyImporter, allowedContentTypes: [.data, .item]) { result in
            importPrivateKey(result, into: profile)
        }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch test {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    // MARK: Protocol fields

    @ViewBuilder
    private func s3Fields(_ settings: Binding<S3Settings>) -> some View {
        TextField("Endpoint", text: settings.endpoint, prompt: Text(verbatim: "s3.amazonaws.com"))
        TextField("Region", text: settings.region, prompt: Text(verbatim: "us-east-1"))
        TextField("Access Key ID", text: settings.accessKeyID)
        SecureField("Secret Access Key", text: $secrets.secretKey)
        Toggle("Use HTTPS", isOn: settings.useHTTPS)
        Toggle("Path-Style Access", isOn: settings.usePathStyle)
    }

    @ViewBuilder
    private func sftpFields(_ settings: Binding<SFTPSettings>) -> some View {
        hostFields(host: settings.host, port: settings.port)
        TextField("Username", text: settings.username)
        Picker("Authentication", selection: settings.authentication) {
            Text("Password").tag(SFTPAuthentication.password)
            Text("Private Key").tag(SFTPAuthentication.privateKey)
        }
        if settings.wrappedValue.authentication == .password {
            SecureField("Password", text: $secrets.password)
        } else {
            LabeledContent("Private Key") {
                HStack {
                    if !settings.wrappedValue.privateKeyName.isEmpty {
                        Text(settings.wrappedValue.privateKeyName)
                            .foregroundStyle(.secondary)
                    }
                    Button("Choose…") { showsKeyImporter = true }
                }
            }
            SecureField("Passphrase", text: $secrets.passphrase)
        }
    }

    @ViewBuilder
    private func ftpFields(_ settings: Binding<FTPSettings>) -> some View {
        hostFields(host: settings.host, port: settings.port)
        TextField("Username", text: settings.username, prompt: Text(verbatim: "anonymous"))
        SecureField("Password", text: $secrets.password)
        Picker("Encryption", selection: settings.encryption) {
            Text("None").tag(FTPEncryption.none)
            Text("Explicit TLS").tag(FTPEncryption.explicitTLS)
            Text("Implicit TLS").tag(FTPEncryption.implicitTLS)
        }
        .onChange(of: settings.wrappedValue.encryption) { old, new in
            if new == .implicitTLS, settings.wrappedValue.port == 21 {
                settings.wrappedValue.port = 990
            } else if old == .implicitTLS, settings.wrappedValue.port == 990 {
                settings.wrappedValue.port = 21
            }
        }
        Picker("Transfer Mode", selection: settings.mode) {
            Text("Passive").tag(FTPTransferMode.passive)
            Text("Active").tag(FTPTransferMode.active)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private func webDAVFields(_ settings: Binding<WebDAVSettings>) -> some View {
        TextField("URL", text: settings.url, prompt: Text(verbatim: "https://example.com/dav/"))
        TextField("Username", text: settings.username)
        SecureField("Password", text: $secrets.password)
    }

    @ViewBuilder
    private func smbFields(_ settings: Binding<SMBSettings>) -> some View {
        TextField("Server", text: settings.server, prompt: Text(verbatim: "nas.local"))
        TextField("Share", text: settings.share)
        TextField("Username", text: settings.username)
        SecureField("Password", text: $secrets.password)
        TextField("Domain", text: settings.domain, prompt: Text(verbatim: "WORKGROUP"))
    }

    private func hostFields(host: Binding<String>, port: Binding<Int>) -> some View {
        Group {
            TextField("Host", text: host, prompt: Text(verbatim: "example.com"))
            TextField("Port", value: port, format: .number.grouping(.never))
        }
    }

    // MARK: Actions

    private func loadRequest() {
        guard profile == nil, case .edit(let existing) = request else { return }
        profile = existing
        do {
            secrets = try KeychainStore.secrets(for: existing.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Tests the draft without saving it: validates the credentials and opens the initial path.
    private func testConnection() {
        guard let profile else { return }
        test = .testing
        let secrets = secrets
        Task {
            do {
                let provider = try pool.makeProvider(for: profile, secrets: secrets)
                if profile.initialRemotePath.isRoot {
                    try await provider.connect()
                } else {
                    _ = try await provider.item(at: profile.initialRemotePath)
                }
                await provider.disconnect()
                test = .succeeded
            } catch {
                test = .failed(PresentableError(error).message)
            }
        }
    }

    private func save() {
        guard let profile else { return }
        do {
            try store.save(profile, secrets: secrets)
            didSave(profile)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Reads the key into the Keychain so it stays available without file access.
    private func importPrivateKey(_ result: Result<URL, any Error>, into profile: Binding<ConnectionProfile>) {
        do {
            let url = try result.get()
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            secrets.privateKey = try String(contentsOf: url, encoding: .utf8)
            profile.wrappedValue.sftp.privateKeyName = url.lastPathComponent
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A group name field with a menu of existing groups.
private struct GroupField: View {
    @Binding var group: String
    let groups: [String]

    var body: some View {
        HStack {
            TextField("Group", text: $group)
            if !groups.isEmpty {
                Menu {
                    ForEach(groups, id: \.self) { name in
                        Button(name) { group = name }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Existing Groups")
            }
        }
    }
}

/// The first step of adding a connection.
private struct ProtocolPicker: View {
    let choose: (ConnectionKind) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("New Connection")
                .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(ConnectionKind.allCases) { kind in
                    Button {
                        choose(kind)
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: kind.systemImage)
                                .font(.system(size: 26))
                                .frame(height: 32)
                            Text(kind.title)
                        }
                        .frame(maxWidth: .infinity, minHeight: 76)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("protocol-\(kind.rawValue)")
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
    }
}
