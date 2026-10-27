// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cTerm",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "cTerm", targets: ["cTerm"])
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.9.2"),
        .package(url: "https://github.com/Joannis/swift-nio-ssh.git", "0.3.2"..<"0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0")
    ],
    targets: [
        .target(
            name: "TerminalCore",
            path: "Sources/TerminalCore"
        ),
        .executableTarget(
            name: "cTerm",
            dependencies: [
                "TerminalCore",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ],
            path: "Sources/cTerm"
        ),
        .testTarget(
            name: "TerminalCoreTests",
            dependencies: ["TerminalCore"],
            path: "Tests/TerminalCoreTests"
        ),
        .testTarget(
            name: "cTermTests",
            dependencies: ["cTerm"],
            path: "Tests/cTermTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
