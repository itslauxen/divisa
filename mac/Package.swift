// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Divisa",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Divisa", path: "Sources/Divisa")
    ]
)
