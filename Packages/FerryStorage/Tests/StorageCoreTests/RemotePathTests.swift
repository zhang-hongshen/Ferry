import Testing
@testable import StorageCore

struct RemotePathTests {
    @Test func normalizesComponents() {
        #expect(RemotePath("/a//b/./c/../d/").string == "/a/b/d")
        #expect(RemotePath("").isRoot)
        #expect(RemotePath("/..").isRoot)
    }

    @Test func navigatesParentsAndAncestors() {
        let path = RemotePath("/bucket/photos/2024")
        #expect(path.name == "2024")
        #expect(path.parent == RemotePath("/bucket/photos"))
        #expect(path.ancestors.map(\.string) == ["/", "/bucket", "/bucket/photos", "/bucket/photos/2024"])
        #expect(RemotePath.root.parent == nil)
    }

    @Test func computesRelativeComponents() {
        let base = RemotePath("/a/b")
        #expect(RemotePath("/a/b/c/d").relativeComponents(to: base) == ["c", "d"])
        #expect(RemotePath("/a/x").relativeComponents(to: base) == nil)
        #expect(base.appending("c/d") == RemotePath("/a/b/c/d"))
    }
}

struct StorageErrorTests {
    @Test func mapsBlockedPlainHTTPToConfigurationError() {
        let error = StorageError.wrapping(URLError(.appTransportSecurityRequiresSecureConnection))
        guard case .invalidConfiguration = error as? StorageError else {
            Issue.record("Expected invalidConfiguration, got \(error)")
            return
        }
    }
}
