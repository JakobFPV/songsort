// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SongSortCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SongSortCore", targets: ["SongSortCore"]),
    ],
    targets: [
        .target(name: "SongSortCore"),
        .testTarget(name: "SongSortCoreTests", dependencies: ["SongSortCore"]),
    ]
)
