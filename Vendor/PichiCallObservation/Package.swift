// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PichiCallObservation", platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "PichiCallObservation", targets: ["PichiCallObservation"])],
    targets: [.target(name: "PichiCallObservation"), .testTarget(name: "PichiCallObservationTests", dependencies: ["PichiCallObservation"])])
