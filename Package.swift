// swift-tools-version: 6.0
// GardenKit: the Apple side of Garden (shared on-device models). The Android library lives in android/.
import PackageDescription

let package = Package(
    name: "Garden",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "GardenKit", targets: ["GardenKit"])],
    targets: [
        .target(
            name: "GardenKit",
            path: "apple/Sources/GardenKit"
        ),
        .testTarget(
            name: "GardenKitTests",
            dependencies: ["GardenKit"],
            path: "apple/Tests/GardenKitTests"
        ),
    ]
)
