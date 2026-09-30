// swift-tools-version:5.9
import PackageDescription

// FlightCore holds everything that doesn't need UIKit, SwiftUI or ActivityKit:
// models, data clients, geo math, polling rules and change detection.
// Keeping it Foundation-only means `swift test` runs on Linux CI as well as macOS.
let package = Package(
    name: "FlightCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FlightCore", targets: ["FlightCore"]),
        .executable(name: "flightcheck", targets: ["flightcheck"]),
    ],
    targets: [
        .target(name: "FlightCore"),
        .executableTarget(name: "flightcheck", dependencies: ["FlightCore"]),
        .testTarget(
            name: "FlightCoreTests",
            dependencies: ["FlightCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
