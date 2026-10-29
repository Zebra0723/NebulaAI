// swift-tools-version:5.10
import PackageDescription

// NebulaCore is pure Swift (no camera, no AppKit), so the recognizer, its
// tests, the latency benchmark and the accuracy report build and run
// anywhere, Linux included. The app itself only builds on macOS.
var targets: [Target] = [
    .target(
        name: "NebulaCore",
        path: "Sources/NebulaCore"
    ),
    .target(name: "NebulaSim", dependencies: ["NebulaCore"], path: "Sources/NebulaSim"),
    .executableTarget(name: "nebula-report", dependencies: ["NebulaCore", "NebulaSim"], path: "Sources/NebulaReport"),
    .target(name: "AllocCounter", path: "Sources/AllocCounter"),
    .testTarget(
        name: "NebulaCoreTests",
        dependencies: ["NebulaCore", "NebulaSim", "AllocCounter"],
        path: "Tests/NebulaCoreTests"
    ),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "Nebula",
        // NebulaSim too: Galaxy Trainer's workouts run simulated hands through the real recognizer.
        dependencies: ["NebulaCore", "NebulaSim"],
        path: "Sources/Nebula",
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("AVFoundation"),
            .linkedFramework("Vision"),
            .linkedFramework("CoreAudio"),
            .linkedFramework("ApplicationServices"),
            .linkedFramework("Carbon"),
        ]
    )
)
#endif

let package = Package(
    name: "Nebula",
    platforms: [.macOS(.v14)],
    targets: targets
)
