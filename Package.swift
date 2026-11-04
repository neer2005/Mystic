// swift-tools-version:6.0
import Foundation
import PackageDescription

// The ABI's static library is built by engine/scripts/test-c-abi.sh, not by SwiftPM.
// Resolve it relative to this manifest so the linker path is absolute and independent of
// the current working directory.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let engineLibraryPath = "\(packageRoot)/engine/target/release"
// iPhone and iPad builds link the archive scripts/build-engine-ios.sh makes. Device only for now:
// SwiftPM cannot tell a simulator build apart here, which needs an XCFramework later.
let iosEngineLibraryPath = "\(packageRoot)/engine/target/aarch64-apple-ios/release"

// Apple framework targets are intentionally absent from Linux package graphs.
#if os(macOS)
let streamProducts: [Product] = [.library(name: "MysticStream", targets: ["MysticStream"]),
                                 .executable(name: "MysticApp", targets: ["MysticApp"]),
                                 .executable(name: "MysticAWDLHelper", targets: ["MysticAWDLHelper"])]
let streamTargets: [Target] = [
    .target(name: "MysticDesktop", dependencies: ["MysticStream", "MysticKit", "MysticCore"]),
    .executableTarget(name: "MysticApp", dependencies: ["MysticDesktop"]),
    .executableTarget(name: "MysticAWDLHelper", dependencies: ["MysticCore"]),
    .testTarget(name: "MysticDesktopTests", dependencies: ["MysticDesktop", "MysticCore"]),
    .target(name: "MysticStream", dependencies: ["MysticCore", "MysticKit"],
            resources: [.copy("Fixtures")]),
    .testTarget(name: "MysticStreamTests", dependencies: ["MysticStream"],
                resources: [.copy("Fixtures")]),
]
#else
let streamProducts: [Product] = []
let streamTargets: [Target] = []
#endif

let package = Package(
    name: "Mystic",
    platforms: [
        // macOS 27 is Apple-silicon only; there is no Intel fallback to support.
        .macOS("27.0"),
        // Groundwork: MysticCore, MysticKit and MysticStream build for iOS; there is no iOS app
        // yet, and MysticDesktop stays AppKit.
        .iOS("27.0"),
    ],
    products: [
        .library(name: "MysticCore", targets: ["MysticCore"]),
        .library(name: "MysticKit", targets: ["MysticKit"]),
    ] + streamProducts,
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

        // The C ABI header. mystic.h is a symlink to engine/include/mystic.h so there is
        // exactly one definition of the surface.
        .target(
            name: "CMystic",
            path: "Sources/CMystic",
            publicHeadersPath: "include"
        ),

        // The Swift wrapper over the C ABI. Deliberately free of Apple frameworks so it
        // compiles and tests on Linux; Apple decoding lives in MysticStream.
        .target(
            name: "MysticKit",
            dependencies: ["CMystic", "MysticCore"],
            linkerSettings: [
                .unsafeFlags(["-L\(engineLibraryPath)", "-lmystic_ffi"], .when(platforms: [.macOS, .linux])),
                .unsafeFlags(["-L\(iosEngineLibraryPath)", "-lmystic_ffi"], .when(platforms: [.iOS])),
                .unsafeFlags(["-ldl"], .when(platforms: [.linux])),
            ]
        ),

        .testTarget(name: "MysticCoreTests", dependencies: ["MysticCore"]),
        .testTarget(name: "MysticKitTests", dependencies: ["MysticKit"]),
    ] + streamTargets
)
