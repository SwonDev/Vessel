// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vessel",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Vessel", targets: ["Vessel"])
    ],
    targets: [
        .executableTarget(
            name: "Vessel",
            path: "Sources/Vessel"
        ),
        .testTarget(
            name: "VesselTests",
            dependencies: ["Vessel"],
            path: "Tests/VesselTests"
        )
    ]
)
