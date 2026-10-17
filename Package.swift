// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "dynamic",
    platforms: [.macOS(.v13)],
    dependencies: [
        // An unofficial CQL driver built on SwiftNIO. It has no license file, so it stays an
        // external dependency, pinned to the revision this project was written against.
        .package(url: "https://gitlab.nexustls.com/libraries/nio-scylladb.git",
                 revision: "2253402f0ff803d7966eddde6ec97105f3cfa1d0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "dynamic",
            dependencies: [
                .product(name: "NIOScyllaDB", package: "nio-scylladb"),
                .product(name: "NIO", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "dynamicTests",
            dependencies: ["dynamic"]
        ),
    ]
)
