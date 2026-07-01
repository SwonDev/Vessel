// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Vessel",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Vessel", targets: ["Vessel"])
    ],
    dependencies: [
        // Parser YAML estándar de Swift — para leer con seguridad el manifiesto de rutas de
        // guardado (ludusavi) en el sistema de copias de partidas. Evita un parser casero frágil.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        // Efecto shimmer para estados de carga premium (mismo que usa Mythic). Modificador
        // ligero: mientras una carátula/ficha carga, muestra un brillo en vez de un hueco plano.
        .package(url: "https://github.com/markiv/SwiftUI-Shimmer.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Vessel",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "Shimmer", package: "SwiftUI-Shimmer")
            ],
            path: "Sources/Vessel"
        ),
        .testTarget(
            name: "VesselTests",
            dependencies: ["Vessel"],
            path: "Tests/VesselTests"
        )
    ]
)
