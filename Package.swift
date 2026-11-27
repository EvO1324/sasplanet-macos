// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SASPlanet",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "SASPlanet",
            path: "Sources/SASPlanet",
            swiftSettings: [.unsafeFlags(["-Ounchecked"])],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
