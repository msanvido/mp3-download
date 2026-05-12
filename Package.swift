// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MP3Download",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "MP3Download",
            path: "Sources/MP3Download"
        ),
        .executableTarget(
            name: "TapTest",
            path: "Sources/TapTest"
        )
    ]
)
