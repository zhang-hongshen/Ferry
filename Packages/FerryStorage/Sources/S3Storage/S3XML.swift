import Foundation
import StorageCore

/// A minimal XML element tree, enough for S3 responses.
final class S3XMLElement {
    let name: String
    var text = ""
    var children: [S3XMLElement] = []

    init(name: String) {
        self.name = name
    }

    func child(_ name: String) -> S3XMLElement? {
        children.first { $0.name == name }
    }

    func children(_ name: String) -> [S3XMLElement] {
        children.filter { $0.name == name }
    }

    /// The trimmed text of the first child named `name`.
    func value(_ name: String) -> String? {
        child(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ data: Data) throws -> S3XMLElement {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            let detail = parser.parserError?.localizedDescription ?? "Empty document"
            throw StorageError.invalidResponse("Malformed XML: \(detail)")
        }
        return root
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: S3XMLElement?
        private var stack: [S3XMLElement] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = S3XMLElement(name: elementName)
            stack.last?.children.append(node)
            if root == nil {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }
    }
}

enum S3XMLWriter {
    static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

enum S3Dates {
    static func parseISO8601(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(string)
    }

    static func parseHTTP(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }
}

extension String {
    /// Removes the quotes S3 puts around ETags.
    var unquoted: String {
        trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}
