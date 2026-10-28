// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FerryStorage",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FerryStorage", targets: ["StorageCore", "S3Storage", "SFTPStorage", "WebDAVStorage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.15.1"),
    ],
    targets: [
        .target(name: "StorageCore"),
        .target(name: "S3Storage", dependencies: ["StorageCore"]),
        .target(
            name: "SFTPStorage",
            dependencies: [
                "StorageCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ]
        ),
        .target(name: "WebDAVStorage", dependencies: ["StorageCore"]),
        .testTarget(name: "StorageCoreTests", dependencies: ["StorageCore"]),
        .testTarget(name: "S3StorageTests", dependencies: ["S3Storage"]),
        .testTarget(name: "WebDAVStorageTests", dependencies: ["WebDAVStorage"]),
        .testTarget(
            name: "SFTPStorageTests",
            dependencies: ["SFTPStorage", .product(name: "NIOEmbedded", package: "swift-nio")]
        ),
    ]
)
