// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RussianMorphology",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "PichiRussianMorphology", type: .static, targets: ["PichiRussianMorphology"])],
    targets: [
        .target(name: "CRussianMorphology", exclude: ["Data"], publicHeadersPath: "include",
                cxxSettings: [.define("NAMESPACE", to: "libmorph::rus"),
                              .headerSearchPath("libmorph"), .headerSearchPath("libmorph/lang-rus/libdict"),
                              .headerSearchPath("."), .headerSearchPath("Data")]),
        .target(name: "PichiRussianMorphology", dependencies: ["CRussianMorphology"]),
        .testTarget(name: "PichiRussianMorphologyTests", dependencies: ["PichiRussianMorphology"]),
    ],
    cxxLanguageStandard: .cxx17
)
