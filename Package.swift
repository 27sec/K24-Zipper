// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "K24Zipper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "K24Zipper", targets: ["K24Zipper"]),
    ],
    targets: [
        .target(name: "ZipperCore"),
        .executableTarget(name: "K24Zipper", dependencies: ["ZipperCore"]),
    ]
)
