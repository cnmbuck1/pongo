// swift-tools-version:5.9
// SpinCore: platform-independent simulation core for Pongo: 3D Table Tennis.
// Contains ball physics, collisions, match rules, AI and input models.
// It has no dependency on SceneKit/UIKit so it can be unit tested on any
// platform (macOS, Linux) and reused by a future renderer or a game server.
import PackageDescription

let package = Package(
    name: "SpinCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "SpinCore", targets: ["SpinCore"])
    ],
    targets: [
        .target(name: "SpinCore", path: "Sources/SpinCore"),
        .testTarget(name: "SpinCoreTests", dependencies: ["SpinCore"], path: "Tests/SpinCoreTests")
    ]
)
