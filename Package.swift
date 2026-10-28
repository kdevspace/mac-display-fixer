// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nbd",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Private CGVirtualDisplay ObjC classes (declared via a reverse-engineered
        // header; the classes live in the CoreGraphics binary and are exported
        // by its .tbd, so no special linking is required).
        .target(
            name: "CGVirtualDisplayKit",
            path: "Sources/CGVirtualDisplayKit"
        ),
        .executableTarget(
            name: "nbd",
            dependencies: ["CGVirtualDisplayKit"],
            path: "Sources/nbd",
            linkerSettings: [
                .linkedFramework("CoreGraphics")
            ]
        )
    ]
)

