// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PichiGigaAM",
    platforms: [.macOS(.v14), .iOS("18.0")],
    products: [.library(name: "PichiGigaAM", targets: ["PichiGigaAM"])],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
    ],
    targets: [
        .target(
            name: "PichiGigaAM",
            dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .testTarget(name: "PichiGigaAMTests", dependencies: ["PichiGigaAM"]),
    ]
)
