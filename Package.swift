// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Index",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "IndexApp", targets: ["IndexApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/nodes-app/swift-markdown-engine.git", from: "0.1.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.0.2"),
        .package(url: "https://github.com/MacPaw/OpenAI.git", from: "0.5.1")
    ],
    targets: [
        .executableTarget(
            name: "IndexApp",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
                .product(name: "MarkdownEngineLatex", package: "swift-markdown-engine"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "OpenAI", package: "OpenAI")
            ],
            path: "Sources/IndexApp",
            exclude: [
                "README.md",
                "Plugins/Capture/README.md",
                "Plugins/Capture/Magnifier/README.md",
                "Plugins/Capture/Metadata/README.md",
                "Plugins/Capture/Overlay/README.md",
                "Plugins/Capture/Selection/README.md",
                "Plugins/Capture/Snapshot/README.md",
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
