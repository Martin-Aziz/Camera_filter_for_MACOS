// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PrivateCamSegmentationPrototype",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PrivateCamSegmentation", targets: ["PrivateCamSegmentation"]),
        .executable(name: "segmentation-benchmark", targets: ["SegmentationBenchmark"])
    ],
    targets: [
        .target(name: "PrivateCamSegmentation"),
        .executableTarget(name: "SegmentationBenchmark", dependencies: ["PrivateCamSegmentation"]),
        .testTarget(
            name: "PrivateCamSegmentationTests",
            dependencies: ["PrivateCamSegmentation"],
            resources: [.process("Fixtures")]
        )
    ]
)
