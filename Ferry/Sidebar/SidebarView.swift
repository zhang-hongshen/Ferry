import StorageCore
import SwiftUI

enum SidebarItem: Hashable {
    case connection(UUID)
    case bucket(UUID, String)
}

/// Connections grouped by group name, with favorites first. S3 connections expand to their buckets.
struct SidebarView: View {
    let model: BrowserWindowModel
    @Binding var editorRequest: ConnectionEditorRequest?

    @Environment(ConnectionStore.self) private var store
    @Environment(ConnectionPool.self) private var pool
    @State private var selection: SidebarItem?
    @State private var expanded: Set<UUID> = []
    @State private var pendingDeletion: ConnectionProfile?
    @State private var bucketCreation: ConnectionProfile?
    @State private var bucketDeletion: BucketDeletion?
    @State private var groupCreation: ConnectionProfile?
    @State private var newName = ""
    @State private var error: PresentableError?

    struct BucketDeletion: Identifiable {
        let profile: ConnectionProfile
        let bucket: String
        var isNotEmpty = false
        var id: String { profile.id.uuidString + bucket }
    }

    var body: some View {
        List(selection: $selection) {
            if !store.favorites.isEmpty {
                Section("Favorites") {
                    ForEach(store.favorites) { profile in
                        row(for: profile)
                    }
                }
            }
            ForEach(store.groups, id: \.self) { group in
                Section(group.isEmpty ? String(localized: "Connections") : group) {
                    ForEach(store.profiles(in: group).filter { !$0.isFavorite }) { profile in
                        row(for: profile)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.profiles.isEmpty {
                ContentUnavailableView {
                    Label("No Connections", systemImage: "externaldrive.badge.plus")
                } actions: {
                    Button("Add Connection") { editorRequest = .new }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    editorRequest = .new
                } label: {
                    Label("Add Connection", systemImage: "plus")
                }
                .accessibilityIdentifier("addConnectionButton")
            }
        }
        .onChange(of: selection) { _, newValue in
            open(newValue)
        }
        .confirmationDialog(
            String(localized: "Delete “\(pendingDeletion?.displayName ?? "")”?"),
            isPresented: $pendingDeletion.isPresent(), presenting: pendingDeletion
        ) { profile in
            Button("Delete", role: .destructive) { deleteConnection(profile) }
        } message: { _ in
            Text("Its saved credentials are removed from the Keychain.")
        }
        .confirmationDialog(
            bucketDeletion?.isNotEmpty == true
                ? String(localized: "“\(bucketDeletion?.bucket ?? "")” isn’t empty. Delete it and all its objects?")
                : String(localized: "Delete bucket “\(bucketDeletion?.bucket ?? "")”?"),
            isPresented: $bucketDeletion.isPresent(), presenting: bucketDeletion
        ) { deletion in
            Button(deletion.isNotEmpty ? "Delete All Objects and Bucket" : "Delete", role: .destructive) {
                deleteBucket(deletion)
            }
        } message: { _ in
            Text("This can’t be undone.")
        }
        .alert("New Bucket", isPresented: $bucketCreation.isPresent(), presenting: bucketCreation) { profile in
            TextField("Name", text: $newName)
            Button("Create") { createBucket(named: newName, in: profile) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Group", isPresented: $groupCreation.isPresent(), presenting: groupCreation) { profile in
            TextField("Name", text: $newName)
            Button("Create") { store.moveProfile(id: profile.id, toGroup: newName.trimmingCharacters(in: .whitespaces)) }
            Button("Cancel", role: .cancel) {}
        }
        .alert(error?.title ?? "", isPresented: $error.isPresent(), presenting: error) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.message)
        }
    }

    @ViewBuilder
    private func row(for profile: ConnectionProfile) -> some View {
        if profile.kind == .s3 {
            DisclosureGroup(isExpanded: expansionBinding(for: profile)) {
                bucketRows(for: profile)
            } label: {
                connectionLabel(profile)
            }
            .tag(SidebarItem.connection(profile.id))
        } else {
            connectionLabel(profile)
                .tag(SidebarItem.connection(profile.id))
        }
    }

    private func connectionLabel(_ profile: ConnectionProfile) -> some View {
        Label(profile.displayName, systemImage: profile.kind.systemImage)
            .contextMenu { connectionMenu(for: profile) }
            .accessibilityHint(profile.kind.title)
    }

    @ViewBuilder
    private func bucketRows(for profile: ConnectionProfile) -> some View {
        if let message = pool.bucketErrors[profile.id] {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else if let buckets = pool.buckets[profile.id] {
            ForEach(buckets, id: \.self) { bucket in
                Label(bucket, systemImage: "archivebox")
                    .tag(SidebarItem.bucket(profile.id, bucket))
                    .contextMenu {
                        Button("Open in New Tab") {
                            model.newTab(opening: profile, at: RemotePath(components: [bucket]))
                        }
                        Divider()
                        Button("Delete Bucket…", role: .destructive) {
                            bucketDeletion = BucketDeletion(profile: profile, bucket: bucket)
                        }
                    }
            }
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func connectionMenu(for profile: ConnectionProfile) -> some View {
        Button("Open in New Tab") {
            model.newTab(opening: profile)
        }
        Divider()
        if profile.kind == .s3 {
            Button("New Bucket…") {
                newName = ""
                bucketCreation = profile
            }
            Button("Refresh Buckets") {
                Task { await pool.loadBuckets(for: profile) }
            }
            Divider()
        }
        Button("Edit…") {
            editorRequest = .edit(profile)
        }
        Button("Duplicate") {
            do {
                try store.duplicate(id: profile.id)
            } catch {
                self.error = PresentableError(error)
            }
        }
        Button(profile.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            store.toggleFavorite(id: profile.id)
        }
        Menu("Group") {
            Button("None") { store.moveProfile(id: profile.id, toGroup: "") }
            Divider()
            ForEach(store.namedGroups, id: \.self) { group in
                Button(group) { store.moveProfile(id: profile.id, toGroup: group) }
            }
            Divider()
            Button("New Group…") {
                newName = ""
                groupCreation = profile
            }
        }
        Divider()
        Button("Delete…", role: .destructive) {
            pendingDeletion = profile
        }
    }

    private func expansionBinding(for profile: ConnectionProfile) -> Binding<Bool> {
        Binding {
            expanded.contains(profile.id)
        } set: { isExpanded in
            if isExpanded {
                expanded.insert(profile.id)
                Task { await pool.loadBuckets(for: profile) }
            } else {
                expanded.remove(profile.id)
            }
        }
    }

    private func open(_ item: SidebarItem?) {
        switch item {
        case .connection(let id):
            if let profile = store.profile(id: id) {
                model.open(profile)
            }
        case .bucket(let id, let bucket):
            if let profile = store.profile(id: id) {
                model.open(profile, at: RemotePath(components: [bucket]))
            }
        case nil:
            break
        }
    }

    private func deleteConnection(_ profile: ConnectionProfile) {
        do {
            pool.invalidate(profile.id)
            try store.remove(id: profile.id)
        } catch {
            self.error = PresentableError(error)
        }
    }

    private func createBucket(named name: String, in profile: ConnectionProfile) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            do {
                try await pool.provider(for: profile).createBucket(named: name)
                await pool.loadBuckets(for: profile)
                refreshTabs(showing: profile)
            } catch {
                self.error = PresentableError(error)
            }
        }
    }

    /// Deletes an empty bucket; a non-empty one asks again before deleting its objects.
    private func deleteBucket(_ deletion: BucketDeletion) {
        Task {
            do {
                try await pool.provider(for: deletion.profile).deleteBucket(named: deletion.bucket,
                                                                            force: deletion.isNotEmpty)
                await pool.loadBuckets(for: deletion.profile)
                refreshTabs(showing: deletion.profile)
            } catch StorageError.directoryNotEmpty where !deletion.isNotEmpty {
                var retry = deletion
                retry.isNotEmpty = true
                bucketDeletion = retry
            } catch {
                self.error = PresentableError(error)
            }
        }
    }

    private func refreshTabs(showing profile: ConnectionProfile) {
        model.tabs.filter { $0.profile?.id == profile.id && $0.path.isRoot }.forEach { $0.refresh() }
    }
}
