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
            path: "Artifacts/TranscribeCpp.xcframework.zip"
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
