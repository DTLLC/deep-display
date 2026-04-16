// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "DeepDisplay",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DeepDisplay", targets: ["DeepDisplay"])
    ],
    targets: [
        .executableTarget(
            name: "DeepDisplay",
            path: "Sources"
        )
    ]
)
