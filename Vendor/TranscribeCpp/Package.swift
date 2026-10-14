// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "transcribe-cpp-swift",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "TranscribeCpp", targets: ["TranscribeCpp"]),
    ],
    targets: [
        .binaryTarget(
            name: "CTranscribe",
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.1.2/TranscribeCpp.xcframework.zip",
            checksum: "4092276cd295860ae9637a2913cf2d8747f39d454bb7fb3c79d6af9f858a4bb8"
        ),
        .target(
            name: "TranscribeCpp",
            dependencies: ["CTranscribe"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .testTarget(
            name: "TranscribeCppTests",
            dependencies: ["TranscribeCpp"]
        ),
    ]
)
