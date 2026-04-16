// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MacRes",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacRes", targets: ["MacRes"])
    ],
    targets: [
        .executableTarget(
            name: "MacRes",
            path: "Sources"
        )
    ]
)
