// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PichiGigaAM",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "PichiGigaAM", targets: ["PichiGigaAM"]),
        .library(name: "PichiTextPrivacy", targets: ["PichiTextPrivacy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
    ],
    targets: [
        .target(
            name: "PichiGigaAM",
            dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")],
            linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("CoreML"), .linkedFramework("Metal")]
        ),
        .testTarget(name: "PichiGigaAMTests", dependencies: ["PichiGigaAM"]),
        // Text privacy shares the already pinned native ONNX runtime. It has no
        // audio frontend or second inference framework dependency.
        .target(name: "PichiTextPrivacy", dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")]),
        .testTarget(name: "PichiTextPrivacyTests", dependencies: ["PichiTextPrivacy"]),
    ]
)
