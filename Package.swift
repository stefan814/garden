// swift-tools-version: 6.0
// ModelLibraryKit: the iPhone and Mac side of the Model Library (shared on-device models). The Android library lives in android/.
import PackageDescription

let package = Package(
    name: "ModelLibrary",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ModelLibraryKit", targets: ["ModelLibraryKit"])],
    targets: [
        .target(
            name: "ModelLibraryKit",
            path: "apple/Sources/ModelLibraryKit"
        ),
        .testTarget(
            name: "ModelLibraryKitTests",
            dependencies: ["ModelLibraryKit"],
            path: "apple/Tests/ModelLibraryKitTests"
        ),
    ]
)
