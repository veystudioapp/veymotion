// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VeyMotion",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VeyMotion", targets: ["VeyMotionApp"]),
        .executable(name: "vmotion", targets: ["vmotion"]),
        .library(name: "VeyMotionCore", targets: ["VeyMotionCore"]),
    ],
    dependencies: [
        // Pinned: 4.6 uses SwiftUI's @Entry macro, whose plugin ships with Xcode only (Command Line Tools cannot build it).
        .package(url: "https://github.com/airbnb/lottie-ios.git", exact: "4.5.2"),
    ],
    targets: [
        .target(name: "VeyMotionCore", dependencies: [.product(name: "Lottie", package: "lottie-ios")]),
        .target(name: "VeyMotionMCP", dependencies: ["VeyMotionCore"]),
        .executableTarget(name: "VeyMotionApp", dependencies: ["VeyMotionCore", "VeyMotionMCP"]),
        .executableTarget(name: "vmotion", dependencies: ["VeyMotionCore", "VeyMotionMCP"]),
        .testTarget(name: "VeyMotionTests", dependencies: ["VeyMotionCore", "VeyMotionMCP"]),
    ]
)
