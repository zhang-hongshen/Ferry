import Foundation
import Synchronization

/// An in-memory WebDAV server behind URLProtocol. Each test uses its own host, so tests can run in
/// parallel. Collections are rooted at `/dav/`; requests must carry Basic credentials `user:secret`.
final class MockWebDAVProtocol: URLProtocol, @unchecked Sendable {
    struct Store {
        var files: [String: Data] = [:]
        var directories: Set<String> = [""]
        var ignoresRange = false
        var requests: [String] = []
    }

    static let stores = Mutex<[String: Store]>([:])

    static func store(_ host: String) -> Store {
        stores.withLock { $0[host] ?? Store() }
    }

    static func update(_ host: String, _ change: (inout Store) -> Void) {
        stores.withLock { stores in
            var store = stores[host] ?? Store()
            change(&store)
            stores[host] = store
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host()?.hasSuffix(".dav.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        let (status, headers, body) = respond(host: host, url: url)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func readBody() -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    /// The path below `/dav`, without leading or trailing slashes.
    private static func relativePath(_ url: URL) -> String? {
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/dav") else { return nil }
        return path.dropFirst(4).split(separator: "/").joined(separator: "/")
    }

    private static func parent(_ path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    private func respond(host: String, url: URL) -> (Int, [String: String], Data) {
        let method = request.httpMethod ?? "GET"
        Self.update(host) { $0.requests.append(method) }
        let expected = "Basic " + Data("user:secret".utf8).base64EncodedString()
        guard request.value(forHTTPHeaderField: "Authorization") == expected else {
            return (401, ["WWW-Authenticate": "Basic realm=\"test\""], Data())
        }
        guard let path = Self.relativePath(url) else { return (404, [:], Data()) }
        var store = Self.store(host)
        defer { Self.update(host) { $0 = store } }
        let isDirectory = store.directories.contains(path)
        let exists = isDirectory || store.files[path] != nil

        switch method {
        case "PROPFIND":
            guard exists else { return (404, [:], Data()) }
            var entries = [path]
            if request.value(forHTTPHeaderField: "Depth") == "1", isDirectory {
                let children = (store.directories.filter { !$0.isEmpty } + store.files.keys)
                    .filter { Self.parent($0) == path }
                entries += children.sorted()
            }
            let responses = entries.map { entry in multistatusEntry(entry, store: store) }.joined()
            let xml = "<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\">\(responses)</d:multistatus>"
            return (207, ["Content-Type": "application/xml"], Data(xml.utf8))
        case "MKCOL":
            if exists { return (405, [:], Data()) }
            guard store.directories.contains(Self.parent(path)) else { return (409, [:], Data()) }
            store.directories.insert(path)
            return (201, [:], Data())
        case "PUT":
            guard store.directories.contains(Self.parent(path)) else { return (409, [:], Data()) }
            store.files[path] = readBody()
            return (201, [:], Data())
        case "GET":
            guard let data = store.files[path] else { return (404, [:], Data()) }
            if !store.ignoresRange, let range = request.value(forHTTPHeaderField: "Range"),
               let bounds = Self.parseRange(range, count: data.count) {
                guard bounds.lowerBound < data.count else { return (416, [:], Data()) }
                return (206, ["Content-Range": "bytes \(bounds.lowerBound)-\(bounds.upperBound - 1)/\(data.count)"],
                        data.subdata(in: bounds))
            }
            return (200, [:], data)
        case "DELETE":
            guard exists else { return (404, [:], Data()) }
            remove(path, from: &store)
            return (204, [:], Data())
        case "MOVE", "COPY":
            guard exists, let destinationText = request.value(forHTTPHeaderField: "Destination"),
                  let destinationURL = URL(string: destinationText),
                  let destination = Self.relativePath(destinationURL) else { return (400, [:], Data()) }
            guard store.directories.contains(Self.parent(destination)) else { return (409, [:], Data()) }
            remove(destination, from: &store)
            for directory in store.directories where directory == path || directory.hasPrefix(path + "/") {
                store.directories.insert(destination + directory.dropFirst(path.count))
            }
            for (file, data) in store.files where file == path || file.hasPrefix(path + "/") {
                store.files[destination + file.dropFirst(path.count)] = data
            }
            if method == "MOVE" {
                remove(path, from: &store)
            }
            return (201, [:], Data())
        default:
            return (405, [:], Data())
        }
    }

    private func remove(_ path: String, from store: inout Store) {
        store.directories = store.directories.filter { $0 != path && !$0.hasPrefix(path + "/") }
        store.files = store.files.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
    }

    private func multistatusEntry(_ path: String, store: Store) -> String {
        let isDirectory = store.directories.contains(path)
        let encoded = path.split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? "" }
            .joined(separator: "/")
        let href = "/dav/" + encoded + (isDirectory && !path.isEmpty ? "/" : "")
        let properties = isDirectory
            ? "<d:resourcetype><d:collection/></d:resourcetype>"
            : "<d:resourcetype/><d:getcontentlength>\(store.files[path]?.count ?? 0)</d:getcontentlength>"
                + "<d:getetag>\"etag-\(store.files[path]?.hashValue ?? 0)\"</d:getetag>"
        return """
        <d:response><d:href>\(href)</d:href><d:propstat><d:prop>\(properties)\
        <d:getlastmodified>Tue, 27 Oct 2026 10:00:00 GMT</d:getlastmodified></d:prop>\
        <d:status>HTTP/1.1 200 OK</d:status></d:propstat><d:propstat><d:prop><d:getcontenttype/></d:prop>\
        <d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
        """
    }

    private static func parseRange(_ header: String, count: Int) -> Range<Int>? {
        let parts = header.replacingOccurrences(of: "bytes=", with: "").split(separator: "-")
        guard let start = parts.first.flatMap({ Int($0) }) else { return nil }
        let end = parts.count > 1 ? (Int(parts[1]) ?? count - 1) : count - 1
        return start..<min(end + 1, max(count, start))
    }
}
