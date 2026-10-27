// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Mystic",
    platforms: [
        // macOS 27 is Apple-silicon only; there is no Intel fallback to support.
        .macOS("27.0"),
    ],
    products: [
        .library(name: "MysticCore", targets: ["MysticCore"]),
    ],
    targets: [
        // Platform-neutral protocol logic. Builds and tests on Linux and macOS,
        // so the protocol surface can be developed without an Apple toolchain.
        .target(
            name: "MysticCore",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(name: "MysticCoreTests", dependencies: ["MysticCore"]),
    ]
)
