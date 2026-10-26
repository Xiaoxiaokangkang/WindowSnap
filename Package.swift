// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WindowSnap",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WindowSnap", targets: ["WindowSnap"])
    ],
    targets: [
        .executableTarget(
            name: "WindowSnap",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
