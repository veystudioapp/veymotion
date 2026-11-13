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
    targets: [
        .target(name: "VeyMotionCore"),
        .target(name: "VeyMotionMCP", dependencies: ["VeyMotionCore"]),
        .executableTarget(name: "VeyMotionApp", dependencies: ["VeyMotionCore", "VeyMotionMCP"]),
        .executableTarget(name: "vmotion", dependencies: ["VeyMotionCore", "VeyMotionMCP"]),
        .testTarget(name: "VeyMotionTests", dependencies: ["VeyMotionCore", "VeyMotionMCP"]),
    ]
)
