import Foundation
import UniformTypeIdentifiers

/// Finder-style "Kind" names for remote files.
///
/// Finder asks Launch Services, which names a file after the document type its default app declares
/// (e.g. "Microsoft Excel Workbook" instead of the system's "Office Open XML spreadsheet"). Launch
/// Services only describes local files, so an empty placeholder per extension is created and queried.
enum FileKindDescriptions {
    private static var cache: [String: String] = [:]

    private static var placeholders: URL {
        AppDirectories.caches.appending(path: "KindPlaceholders", directoryHint: .isDirectory)
    }

    static func description(forExtension pathExtension: String) -> String? {
        let key = pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let description = launchServicesDescription(forExtension: key)
            ?? UTType(filenameExtension: key)?.localizedDescription
        if let description { cache[key] = description }
        return description
    }

    private static func launchServicesDescription(forExtension pathExtension: String) -> String? {
        guard !pathExtension.isEmpty, !pathExtension.contains("/") else { return nil }
        let url = placeholders.appending(path: "placeholder.\(pathExtension)", directoryHint: .notDirectory)
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: placeholders, withIntermediateDirectories: true)
                try Data().write(to: url)
            }
            return try url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription
        } catch {
            // The UTType description is the fallback; the placeholder is only an optimization.
            return nil
        }
    }
}
