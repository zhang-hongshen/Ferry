import Foundation
import Synchronization
import Testing
@testable import StorageCore
@testable import WebDAVStorage

struct WebDAVParsingTests {
    @Test func parsesMultistatusWithFailedPropstats() throws {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:response>
            <d:href>https://cloud.example.com/remote.php/dav/files/alice/Photos%20%282024%29/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype>
              <d:creationdate>2026-10-14T01:11:00Z</d:creationdate>
              <d:getlastmodified>Tue, 27 Oct 2026 10:00:00 GMT</d:getlastmodified></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
            <d:propstat><d:prop><d:getcontentlength/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
          </d:response>
          <D:response xmlns:D="DAV:">
            <D:href>/remote.php/dav/files/alice/a+b.txt</D:href>
            <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>42</D:getcontentlength>
              <D:getetag>"abc"</D:getetag><D:getcontenttype>text/plain</D:getcontenttype></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
        </d:multistatus>
        """
        let resources = try WebDAVMultistatusParser.parse(Data(xml.utf8))
        #expect(resources.count == 2)
        #expect(resources[0].hrefPath == "/remote.php/dav/files/alice/Photos (2024)/")
        #expect(resources[0].isCollection && resources[0].contentLength == nil)
        #expect(resources[0].creationDate == Date(timeIntervalSince1970: 1_791_940_260))
        #expect(resources[1].creationDate == nil)
        #expect(resources[0].lastModified != nil)
        #expect(resources[1].hrefPath == "/remote.php/dav/files/alice/a+b.txt")
        #expect(resources[1].contentLength == 42 && resources[1].eTag == "\"abc\"")
    }

    @Test func mapsPathsBelowTheBaseURL() throws {
        let configuration = try WebDAVConfiguration(url: "https://cloud.example.com/remote.php/dav/files/alice",
                                                    username: "", password: "")
        let provider = WebDAVProvider(configuration: configuration)
        let client = provider.client
        #expect(client.url(for: RemotePath("/Photos (2024)/a b.jpg"), isCollection: false).absoluteString
            == "https://cloud.example.com/remote.php/dav/files/alice/Photos%20%282024%29/a%20b.jpg")
        #expect(client.url(for: RemotePath("/Docs"), isCollection: true).absoluteString.hasSuffix("/alice/Docs/"))
        #expect(client.remotePath(forHrefPath: "/remote.php/dav/files/alice/Docs/x.txt") == RemotePath("/Docs/x.txt"))
        #expect(client.remotePath(forHrefPath: "/elsewhere/x.txt") == nil)
    }

    @Test func rejectsNonHTTPURLs() {
        #expect(throws: StorageError.self) { try WebDAVConfiguration(url: "ftp://example.com", username: "", password: "") }
    }
}

/// End-to-end tests against the in-memory server in `MockWebDAVServer.swift`.
struct WebDAVProviderTests {
    private func makeProvider(_ host: String, password: String = "secret", chunkSize: Int64? = nil) throws -> WebDAVProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockWebDAVProtocol.self]
        let webDAV = try WebDAVConfiguration(url: "https://\(host)/dav/", username: "user", password: password)
        return WebDAVProvider(configuration: webDAV, sessionConfiguration: configuration,
                              downloadChunkSize: chunkSize ?? 8 * 1024 * 1024)
    }

    private func temporaryFile(_ data: Data) throws -> URL {
        let directory = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(filePath: $0) }
            ?? FileManager.default.temporaryDirectory
        let url = directory.appending(path: "webdav-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    private static func sample(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    @Test func createsListsMovesCopiesAndDeletes() async throws {
        let host = "crud.dav.test"
        let provider = try makeProvider(host)
        try await provider.connect()
        try await provider.createDirectory(at: RemotePath("/Docs"))
        await #expect(throws: StorageError.alreadyExists(RemotePath("/Docs"))) {
            try await provider.createDirectory(at: RemotePath("/Docs"))
        }
        let file = try temporaryFile(Data("hello".utf8))
        try await provider.upload(from: file, to: RemotePath("/Docs/a b.txt"), options: TransferOptions(),
                                  reporter: TransferReporter())

        let root = try await provider.listAll(.root)
        #expect(root.map(\.name) == ["Docs"] && root[0].kind == .directory)
        let docs = try await provider.listAll(RemotePath("/Docs"))
        #expect(docs.map(\.name) == ["a b.txt"] && docs[0].size == 5)

        let docsItem = try await provider.item(at: RemotePath("/Docs"))
        try await provider.copy(docsItem, to: RemotePath("/Copy"))
        try await provider.move(docs[0], to: RemotePath("/Docs/renamed.txt"))
        #expect(MockWebDAVProtocol.store(host).files.keys.sorted() == ["Copy/a b.txt", "Docs/renamed.txt"])

        try await provider.delete(try await provider.item(at: RemotePath("/Docs")))
        #expect(try await provider.exists(RemotePath("/Docs")) == false)
        #expect(MockWebDAVProtocol.store(host).requests.contains("COPY"))
    }

    @Test func streamsUploadsThroughTheBoundStream() async throws {
        let host = "upload.dav.test"
        let provider = try makeProvider(host)
        let data = Self.sample(300_000)
        let completed = Mutex<Int64>(0)
        let reporter = TransferReporter(minimumInterval: .zero, onProgress: { snapshot in
            completed.withLock { $0 = snapshot.completedBytes }
        })
        try await provider.upload(from: try temporaryFile(data), to: RemotePath("/big.bin"), options: TransferOptions(),
                                  reporter: reporter)
        #expect(MockWebDAVProtocol.store(host).files["big.bin"] == data)
        #expect(completed.withLock { $0 } == Int64(data.count))
    }

    @Test func resumesDownloadsWithRanges() async throws {
        let host = "download.dav.test"
        let provider = try makeProvider(host, chunkSize: 32 * 1024)
        let data = Self.sample(100_000)
        MockWebDAVProtocol.update(host) { $0.files["file.bin"] = data }
        let item = try await provider.item(at: RemotePath("/file.bin"))
        let token = try #require(item.eTag)

        let destination = try temporaryFile(data.prefix(40_000))
        try await provider.download(RemotePath("/file.bin"), to: destination,
                                    options: TransferOptions(resume: true, resumeToken: token), reporter: TransferReporter())
        #expect(try Data(contentsOf: destination) == data)
        #expect(MockWebDAVProtocol.store(host).requests.filter { $0 == "GET" }.count == 2)
    }

    @Test func handlesServersThatIgnoreRanges() async throws {
        let host = "norange.dav.test"
        let provider = try makeProvider(host, chunkSize: 16 * 1024)
        let data = Self.sample(50_000)
        MockWebDAVProtocol.update(host) {
            $0.files["file.bin"] = data
            $0.ignoresRange = true
        }
        let destination = try temporaryFile(Data(repeating: 9, count: 1000))
        try await provider.download(RemotePath("/file.bin"), to: destination,
                                    options: TransferOptions(resume: true, resumeToken: "stale"), reporter: TransferReporter())
        #expect(try Data(contentsOf: destination) == data)
    }

    @Test func reportsWrongCredentials() async throws {
        let provider = try makeProvider("auth.dav.test", password: "wrong")
        await #expect {
            try await provider.connect()
        } throws: { error in
            if case StorageError.authenticationFailed = error { return true }
            return false
        }
    }

    @Test func reportsMissingParents() async throws {
        let provider = try makeProvider("missing.dav.test")
        await #expect(throws: StorageError.notFound(RemotePath("/nope"))) {
            try await provider.createDirectory(at: RemotePath("/nope/child"))
        }
    }
}
