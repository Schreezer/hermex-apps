// swift-tools-version: 6.0
import PackageDescription

// HermexAppKit is compiled into every app Hermes builds. It connects the app to
// the Hermex host that runs it (BUILD_SPEC §3.2) and does nothing elsewhere.
let package = Package(
    name: "HermexAppKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "HermexAppKit", targets: ["HermexAppKit"])
    ],
    targets: [
        .target(name: "HermexAppKit"),
        .testTarget(name: "HermexAppKitTests", dependencies: ["HermexAppKit"])
    ],
    swiftLanguageModes: [.v5]
)
