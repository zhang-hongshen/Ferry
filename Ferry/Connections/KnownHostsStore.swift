import Foundation
import Observation
import SFTPStorage

/// Trusted SSH host keys, keyed by "host:port". Unknown keys are confirmed by the user; a changed
/// key is rejected.
@Observable
final class KnownHostsStore {
    struct Prompt: Identifiable {
        let id = UUID()
        let key: SFTPHostKey
    }

    private(set) var prompt: Prompt?

    @ObservationIgnored private var trusted: [String: String] = [:]
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = AppDirectories.applicationSupport.appending(path: "known_hosts.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            trusted = stored
        }
    }

    private static func identifier(_ key: SFTPHostKey) -> String {
        "\(key.host.lowercased()):\(key.port)"
    }

    func validate(_ key: SFTPHostKey) async throws {
        let identifier = Self.identifier(key)
        if let known = trusted[identifier] {
            guard known == key.openSSHRepresentation else {
                throw PresentableError(
                    title: String(localized: "Host Key Changed"),
                    message: String(localized: "The identity of \(key.host) changed. If this is not expected, someone may be intercepting the connection."),
                    category: .authentication
                )
            }
            return
        }
        guard await ask(key) else {
            throw PresentableError(title: String(localized: "Host Not Trusted"),
                                   message: String(localized: "The connection to \(key.host) was cancelled."))
        }
        trusted[identifier] = key.openSSHRepresentation
        save()
    }

    /// Forgets a host so its next key is asked about again, for example after a server was reinstalled.
    func forget(host: String, port: Int) {
        trusted["\(host.lowercased()):\(port)"] = nil
        save()
    }

    func answer(trust: Bool) {
        prompt = nil
        continuation?.resume(returning: trust)
        continuation = nil
    }

    private func ask(_ key: SFTPHostKey) async -> Bool {
        // A second connection waiting for the same decision is declined rather than queued.
        guard continuation == nil else { return false }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            prompt = Prompt(key: key)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(trusted).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Ferry: saving known hosts failed: \(error.localizedDescription)")
        }
    }
}
