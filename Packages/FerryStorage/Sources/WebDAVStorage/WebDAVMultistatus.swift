import Foundation
import StorageCore

/// One `<response>` of a PROPFIND multistatus body.
struct WebDAVResource: Sendable, Equatable {
    /// The decoded URL path of the resource, for example `/dav/My Folder/`.
    var hrefPath: String
    var isCollection: Bool
    var contentLength: Int64?
    var creationDate: Date?
    var lastModified: Date?
    var eTag: String?
    var contentType: String?
}

/// Parses `207 Multi-Status` PROPFIND responses (RFC 4918). Element names are matched without namespaces.
final class WebDAVMultistatusParser: NSObject, XMLParserDelegate {
    private var resources: [WebDAVResource] = []
    private var current: WebDAVResource?
    private var text = ""
    /// Properties inside a `<propstat>` whose status is not 200 are ignored.
    private var propstat: WebDAVResource?
    private var propstatOK = true

    static func parse(_ data: Data) throws -> [WebDAVResource] {
        let delegate = WebDAVMultistatusParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else {
            throw StorageError.invalidResponse("Malformed PROPFIND response: \(parser.parserError?.localizedDescription ?? "")")
        }
        return delegate.resources
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "response":
            current = WebDAVResource(hrefPath: "", isCollection: false)
        case "propstat":
            propstat = WebDAVResource(hrefPath: "", isCollection: false)
            propstatOK = true
        case "collection":
            propstat?.isCollection = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href" where propstat == nil:
            current?.hrefPath = Self.decodePath(value)
        case "getcontentlength":
            propstat?.contentLength = Int64(value)
        case "creationdate":
            propstat?.creationDate = Self.parseISO8601Date(value)
        case "getlastmodified":
            propstat?.lastModified = Self.parseHTTPDate(value)
        case "getetag":
            propstat?.eTag = value.isEmpty ? nil : value
        case "getcontenttype":
            propstat?.contentType = value.isEmpty ? nil : value
        case "status" where propstat != nil:
            propstatOK = value.contains(" 200 ")
        case "propstat":
            if propstatOK, let found = propstat, var resource = current {
                resource.isCollection = resource.isCollection || found.isCollection
                resource.contentLength = found.contentLength ?? resource.contentLength
                resource.creationDate = found.creationDate ?? resource.creationDate
                resource.lastModified = found.lastModified ?? resource.lastModified
                resource.eTag = found.eTag ?? resource.eTag
                resource.contentType = found.contentType ?? resource.contentType
                current = resource
            }
            propstat = nil
        case "response":
            if let current, !current.hrefPath.isEmpty {
                resources.append(current)
            }
            current = nil
        default:
            break
        }
        text = ""
    }

    /// `href` is an absolute URL or an absolute path, percent-encoded.
    static func decodePath(_ href: String) -> String {
        if let url = URL(string: href), url.host() != nil {
            return url.path(percentEncoded: false)
        }
        let pathOnly = href.split(separator: "?", maxSplits: 1).first.map(String.init) ?? href
        return pathOnly.removingPercentEncoding ?? pathOnly
    }

    /// `creationdate` is an RFC 3339 timestamp, with or without fractional seconds.
    static func parseISO8601Date(_ string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(string)
    }

    static func parseHTTPDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }
}
