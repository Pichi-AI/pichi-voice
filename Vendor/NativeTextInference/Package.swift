// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NativeTextInference",
    platforms: [.macOS(.v14)],
    products: [.library(name: "NativeTextInference", targets: ["NativeTextInference"])],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11577/llama-b11577-xcframework.zip",
            checksum: "8b2af91c7a1ffe2b3635ed5241bc30f216e64fa6abc15a6f2cbd2ccaaf8813c0"
        ),
        .target(name: "NativeTextInference", dependencies: ["llama"]),
        .testTarget(name: "NativeTextInferenceTests", dependencies: ["NativeTextInference"]),
    ]
)
