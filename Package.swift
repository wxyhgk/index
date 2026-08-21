// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Index",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "IndexApp", targets: ["IndexApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .executableTarget(
            name: "IndexApp",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/IndexApp",
            exclude: [
                "README.md",
                "Capture/README.md",
                "Capture/Magnifier/README.md",
                "Capture/Metadata/README.md",
                "Capture/Overlay/README.md",
                "Capture/Selection/README.md",
                "Capture/Snapshot/README.md",
                "Platform/README.md",
                "Toolbar/README.md"
            ],
            swiftSettings: [
                // 先用 v5 语言模式，避免 Swift 6 严格并发在 AppKit 桥接处大量报错。
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "IndexTests",
            dependencies: [
                "IndexApp",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Tests/IndexTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
