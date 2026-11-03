// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FluidVoice",
    platforms: [
        .macOS("15.0"),
    ],
    dependencies: [
        .package(path: "Vendor/NativeTextInference"),
        .package(path: "Vendor/WebRTCAudioProcessing"),
        .package(path: "Vendor/PichiGigaAM"),
        .package(path: "Vendor/RussianMorphology"),
        .package(url: "https://github.com/mxcl/AppUpdater.git", from: "1.0.0"),
        .package(url: "https://github.com/altic-dev/FluidAudio.git", revision: "386f7195670b77f2954c7ee143ec63fcb50b6c3b"),
        .package(url: "https://github.com/mxcl/PromiseKit", from: "6.0.0"),
        .package(url: "https://github.com/altic-dev/DynamicNotchKit.git", revision: "50dc8565469cc80bbbe3c0d5dd902585a2d67986"),
        .package(path: "Vendor/TranscribeCpp"),
        .package(url: "https://github.com/zepdb/zeppelin-embed.git", exact: "0.4.1"),
    ],
    targets: [
        .target(
            name: "CoreAudioCaptureSupport",
            path: "Sources/CoreAudioCaptureSupport",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
            ]
        ),
        .executableTarget(
            name: "FluidVoice",
            dependencies: [
                .product(name: "NativeTextInference", package: "NativeTextInference"),
                "AppUpdater",
                "CoreAudioCaptureSupport",
                "FluidAudio",
                "PromiseKit",
                "DynamicNotchKit",
                .product(name: "FluidAEC3Bridge", package: "WebRTCAudioProcessing"),
                .product(name: "PichiGigaAM", package: "PichiGigaAM"),
                .product(name: "PichiTextPrivacy", package: "PichiGigaAM"),
                .product(name: "PichiRussianMorphology", package: "RussianMorphology"),
                .product(name: "TranscribeCpp", package: "TranscribeCpp"),
                .product(name: "ZeppelinEmbed", package: "zeppelin-embed"),
            ],
            resources: [
                .copy("Resources/speech-model-check.pcm"),
                .copy("Resources/Notices"),
                .copy("Models/local-text-models.json"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
