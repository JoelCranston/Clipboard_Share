// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "ClipShare",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClipShare", targets: ["ClipShare"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.12.3"..<"5.0.0"),
    ],
    targets: [
        // Reference Argon2 implementation (CC0 / Apache-2.0), vendored from P-H-C/phc-winner-argon2.
        .target(
            name: "CArgon2",
            exclude: ["LICENSE"],
            cSettings: [.headerSearchPath(".")]
        ),
        // Everything needed to talk the omaclip v2 sync protocol, independent of the UI.
        .target(
            name: "OmaclipKit",
            dependencies: [
                "CArgon2",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "ClipShare",
            dependencies: ["OmaclipKit"]
        ),
        .testTarget(
            name: "OmaclipKitTests",
            dependencies: ["OmaclipKit"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
