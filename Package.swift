// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "DshMacos",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DshMacos", targets: ["DshMacos"])
    ],
    targets: [
        .executableTarget(
            name: "DshMacos",
            path: "Sources/DshMacos"
        ),
        .testTarget(
            name: "DshMacosTests",
            dependencies: ["DshMacos"],
            path: "Tests/DshMacosTests"
        )
    ]
)
