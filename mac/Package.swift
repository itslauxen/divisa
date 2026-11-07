// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Divisa",
    platforms: [.macOS(.v14)],
    targets: [
        // Declarações da API privada de tela virtual do CoreGraphics.
        .target(name: "CGVirtual", path: "Sources/CGVirtual"),
        .executableTarget(name: "Divisa", dependencies: ["CGVirtual"], path: "Sources/Divisa",
                          linkerSettings: [.linkedFramework("ScreenCaptureKit")])
    ]
)
