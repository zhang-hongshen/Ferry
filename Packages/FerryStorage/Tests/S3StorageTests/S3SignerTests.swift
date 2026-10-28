import Foundation
import Testing
@testable import S3Storage

/// Test vectors from the AWS "Signature Version 4" examples for Amazon S3.
struct S3SignerTests {
    private let signer = S3Signer(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        sessionToken: nil
    )
    private let date = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z

    @Test func signsGetObjectWithRange() throws {
        let url = try #require(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt"))
        var request = URLRequest(url: url)
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        signer.sign(&request, region: "us-east-1", payloadHash: S3Signer.emptyPayloadHash, date: date)

        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.contains("SignedHeaders=host;range;x-amz-content-sha256;x-amz-date"))
        #expect(authorization.hasSuffix("Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"))
    }

    @Test func presignsGetObject() throws {
        let url = try #require(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt"))
        let presigned = signer.presign(url, region: "us-east-1", expires: 86400, date: date)
        #expect(presigned.absoluteString.hasSuffix(
            "X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
        ))
    }

    @Test func encodesKeysStrictly() {
        #expect(S3Encoding.encodeKey("photos/My File+1.jpg") == "photos/My%20File%2B1.jpg")
    }
}

struct S3ProviderTests {
    private func provider(endpoint: String = "", pathStyle: Bool = false, https: Bool = true) throws -> S3Provider {
        try S3Provider(configuration: S3Configuration(
            endpoint: endpoint, region: "eu-west-1", useHTTPS: https, usePathStyle: pathStyle,
            accessKeyID: "key", secretAccessKey: "secret"
        ))
    }

    @Test func buildsVirtualHostedAndPathStyleURLs() throws {
        let aws = try provider()
        #expect(aws.url(for: RemotePathFixture.object)?.absoluteString
            == "https://bucket.s3.eu-west-1.amazonaws.com/dir/a%20b.txt")

        let minio = try provider(endpoint: "http://localhost:9000/", pathStyle: true, https: false)
        #expect(minio.url(for: RemotePathFixture.object)?.absoluteString
            == "http://localhost:9000/bucket/dir/a%20b.txt")
    }

    @Test func choosesPartSizes() throws {
        let s3 = try provider()
        #expect(s3.partSize(for: 100 * 1024 * 1024) == 8 * 1024 * 1024)
        let huge: Int64 = 200 * 1024 * 1024 * 1024
        #expect(s3.partSize(for: huge) * 10_000 >= huge)
    }

    @Test func rejectsMissingCredentials() {
        #expect(throws: (any Error).self) {
            try S3Provider(configuration: S3Configuration(endpoint: "", region: "us-east-1",
                                                          accessKeyID: "", secretAccessKey: ""))
        }
    }
}

import StorageCore

enum RemotePathFixture {
    static let object = RemotePath("/bucket/dir/a b.txt")
}
