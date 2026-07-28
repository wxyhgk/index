// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacShot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacShot", targets: ["MacShot"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .executableTarget(
            name: "MacShot",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/MacShot",
            swiftSettings: [
                // 先用 v5 语言模式，避免 Swift 6 严格并发在 AppKit 桥接处大量报错。
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "MacShotTests",
            dependencies: [
                "MacShot",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Tests/MacShotTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
