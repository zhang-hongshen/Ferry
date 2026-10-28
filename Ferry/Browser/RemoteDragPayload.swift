import AppKit
import StorageCore
import UniformTypeIdentifiers

/// Remote items dragged between tabs or windows of this app.
nonisolated struct RemoteDragPayload: Codable {
    static let typeIdentifier = "com.zhanghongshen.ferry.remote-items"
    static let contentType = UTType(exportedAs: typeIdentifier, conformingTo: .data)

    let connectionID: UUID
    let items: [RemoteItem]

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        provider.registerDataRepresentation(forTypeIdentifier: Self.typeIdentifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func load(from provider: NSItemProvider) async -> RemoteDragPayload? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data.flatMap { try? JSONDecoder().decode(RemoteDragPayload.self, from: $0) })
            }
        }
    }

    static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
                continuation.resume(returning: (url as? NSURL).map { $0 as URL })
            }
        }
    }
}
