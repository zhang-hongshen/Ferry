import Foundation
import Observation

enum ConflictResolution {
    case replace
    case skip
    case keepBoth
}

/// Asks the user what to do when an item with the same name already exists at the destination.
@Observable
final class ConflictResolver {
    struct Prompt: Identifiable {
        let id = UUID()
        let name: String
        let remaining: Int
    }

    private(set) var prompt: Prompt?
    @ObservationIgnored private var continuation: CheckedContinuation<(ConflictResolution, Bool), Never>?

    /// Resolves the destination name of every item. Returns `nil` for skipped items.
    func resolve(_ names: [String], existing: Set<String>) async -> [String: String?] {
        var taken = existing
        var result: [String: String?] = [:]
        var resolutionForAll: ConflictResolution?
        let conflicting = names.filter { existing.contains($0) }
        for (index, name) in names.enumerated() {
            guard existing.contains(name) else {
                result[name] = name
                taken.insert(name)
                continue
            }
            var resolution = resolutionForAll
            if resolution == nil {
                let remaining = conflicting.count - (conflicting.firstIndex(of: name) ?? index) - 1
                let (answer, applyToAll) = await ask(name: name, remaining: remaining)
                resolution = answer
                if applyToAll {
                    resolutionForAll = answer
                }
            }
            switch resolution ?? .skip {
            case .replace:
                result[name] = name
            case .skip:
                result[name] = .some(nil)
            case .keepBoth:
                let unique = Self.uniqueName(for: name, avoiding: taken)
                taken.insert(unique)
                result[name] = unique
            }
        }
        return result
    }

    func answer(_ resolution: ConflictResolution, applyToAll: Bool) {
        prompt = nil
        continuation?.resume(returning: (resolution, applyToAll))
        continuation = nil
    }

    private func ask(name: String, remaining: Int) async -> (ConflictResolution, Bool) {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            prompt = Prompt(name: name, remaining: remaining)
        }
    }

    /// "photo.jpg" becomes "photo 2.jpg", "photo 3.jpg", and so on.
    static func uniqueName(for name: String, avoiding taken: Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var number = 2
        while true {
            let candidate = pathExtension.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(pathExtension)"
            if !taken.contains(candidate) {
                return candidate
            }
            number += 1
        }
    }
}
