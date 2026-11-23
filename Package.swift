// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Notchi",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Notchi",
            path: "Sources/Notchi",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
