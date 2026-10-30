// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SynoShare",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SynoShareKit", targets: ["SynoShareKit"]),
        .executable(name: "synoshare", targets: ["synoshare"]),
        .executable(name: "SynoShareApp", targets: ["SynoShareApp"]),
    ],
    targets: [
        .target(name: "SynoShareKit"),
        .executableTarget(name: "synoshare", dependencies: ["SynoShareKit"]),
        // App logic (view model, Keychain, preferences) kept out of the views so it is unit-testable.
        .target(name: "SynoShareAppCore", dependencies: ["SynoShareKit"]),
        .executableTarget(name: "SynoShareApp", dependencies: ["SynoShareAppCore", "SynoShareKit"]),
        .testTarget(name: "SynoShareKitTests", dependencies: ["SynoShareKit"]),
        .testTarget(name: "SynoShareAppTests", dependencies: ["SynoShareAppCore", "SynoShareKit"]),
    ]
)
