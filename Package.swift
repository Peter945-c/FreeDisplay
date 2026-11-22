// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FreeDisplay",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "FreeDisplay", targets: ["FreeDisplay"])
    ],
    targets: [
        .executableTarget(
            name: "FreeDisplay",
            path: "Sources/FreeDisplay",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
