import Foundation
import Observation

/// Saved connections, persisted as JSON in Application Support. Secrets go to the Keychain.
@Observable
final class ConnectionStore {
    private(set) var profiles: [ConnectionProfile] = []
    var lastError: String?

    @ObservationIgnored private let fileURL: URL

    private struct ExportFile: Codable {
        var version = 1
        var connections: [ConnectionProfile]
    }

    init(fileURL: URL = AppDirectories.applicationSupport.appending(path: "connections.json")) {
        self.fileURL = fileURL
        load()
    }

    /// Group names in display order. Ungrouped connections have an empty group name.
    var groups: [String] {
        Array(Set(profiles.map(\.group))).sorted { lhs, rhs in
            if lhs.isEmpty != rhs.isEmpty { return lhs.isEmpty }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    var namedGroups: [String] { groups.filter { !$0.isEmpty } }

    func profiles(in group: String) -> [ConnectionProfile] {
        profiles.filter { $0.group == group }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var favorites: [ConnectionProfile] {
        profiles.filter(\.isFavorite)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func profile(id: UUID?) -> ConnectionProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Adds or updates a profile and its secrets.
    func save(_ profile: ConnectionProfile, secrets: ConnectionSecrets) throws {
        try KeychainStore.save(secrets, for: profile.id)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try persist()
    }

    func remove(id: UUID) throws {
        try KeychainStore.deleteSecrets(for: id)
        profiles.removeAll { $0.id == id }
        try persist()
    }

    @discardableResult
    func duplicate(id: UUID) throws -> ConnectionProfile? {
        guard var copy = profile(id: id) else { return nil }
        let secrets = try KeychainStore.secrets(for: id)
        copy.id = UUID()
        copy.name = String(localized: "\(copy.displayName) Copy")
        copy.isFavorite = false
        try save(copy, secrets: secrets)
        return copy
    }

    func toggleFavorite(id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].isFavorite.toggle()
        persistReportingErrors()
    }

    func moveProfile(id: UUID, toGroup group: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].group = group
        persistReportingErrors()
    }

    /// JSON for the given profiles (or all), without any secrets.
    func exportData(ids: Set<UUID>? = nil) throws -> Data {
        let selected = ids.map { ids in profiles.filter { ids.contains($0.id) } } ?? profiles
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(ExportFile(connections: selected))
    }

    /// Imports profiles as new connections. Returns the number imported.
    @discardableResult
    func importProfiles(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let imported = try JSONDecoder().decode(ExportFile.self, from: data).connections
        for var profile in imported {
            profile.id = UUID()
            profiles.append(profile)
        }
        try persist()
        return imported.count
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            profiles = try JSONDecoder().decode([ConnectionProfile].self, from: Data(contentsOf: fileURL))
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: fileURL, options: .atomic)
    }

    private func persistReportingErrors() {
        do {
            try persist()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
