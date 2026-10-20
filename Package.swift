// swift-tools-version: 6.0
//
// EquAudio — system-wide audio enhancer for macOS 14.2+ (Apple Silicon).
// Build with ./build.sh (wraps `swift build` and assembles EquAudio.app); no Xcode project needed.

import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "EquAudio",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "EquAudio", targets: ["EquAudio"]),
        .library(name: "EquAudioKit", targets: ["EquAudioKit"]),
    ],
    targets: [
        // Real-time DSP engine and Core Audio IOProc (C++20 behind a C API, no Swift on the audio thread).
        .target(
            name: "EquCore",
            path: "Sources/EquCore",
            cxxSettings: [.define("NDEBUG", .when(configuration: .release))],
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        // Device routing (process taps + private aggregate devices), presets, settings, recording, diagnostics.
        .target(
            name: "EquAudioKit",
            dependencies: ["EquCore"],
            path: "Sources/EquAudioKit",
            swiftSettings: swift5,
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
            ]
        ),
        // SwiftUI application.
        .executableTarget(
            name: "EquAudio",
            dependencies: ["EquAudioKit"],
            path: "Sources/EquAudio",
            swiftSettings: swift5
        ),
        .testTarget(
            name: "EquCoreTests",
            dependencies: ["EquCore"],
            path: "Tests/EquCoreTests",
            swiftSettings: swift5
        ),
        .testTarget(
            name: "EquAudioKitTests",
            dependencies: ["EquAudioKit", "EquCore"],
            path: "Tests/EquAudioKitTests",
            swiftSettings: swift5
        ),
    ],
    cxxLanguageStandard: .cxx20
)
