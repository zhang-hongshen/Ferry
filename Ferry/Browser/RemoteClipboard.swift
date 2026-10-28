import AppKit
import Observation
import StorageCore

/// Items copied or cut in any tab, pasted into another directory or another connection.
/// Their paths also go on the general pasteboard as text; copying anything else invalidates them.
@Observable
final class RemoteClipboard {
    struct Contents {
        let connectionID: UUID
        let items: [RemoteItem]
        let isCut: Bool
        let text: String
    }

    private(set) var contents: Contents?

    /// Stores the items and returns the pasteboard representation of their paths.
    func set(_ items: [RemoteItem], from connectionID: UUID, isCut: Bool) -> [NSItemProvider] {
        let text = items.map(\.path.string).joined(separator: "\n")
        contents = Contents(connectionID: connectionID, items: items, isCut: isCut, text: text)
        return [NSItemProvider(object: text as NSString)]
    }

    var current: Contents? {
        guard let contents, NSPasteboard.general.string(forType: .string) == contents.text else { return nil }
        return contents
    }

    func clear() {
        contents = nil
    }
}
