// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PrivateCamSegmentationPrototype",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PrivateCamSegmentation", targets: ["PrivateCamSegmentation"]),
        .executable(name: "segmentation-benchmark", targets: ["SegmentationBenchmark"]),
        .executable(name: "skin-quality-audit", targets: ["SkinQualityAudit"]),
        .executable(name: "skin-calibration-audit", targets: ["SkinCalibrationAudit"])
    ],
    targets: [
        .target(name: "PrivateCamSegmentation"),
        .executableTarget(name: "SegmentationBenchmark", dependencies: ["PrivateCamSegmentation"]),
        .executableTarget(name: "SkinQualityAudit", dependencies: ["PrivateCamSegmentation"]),
        .executableTarget(name: "SkinCalibrationAudit", dependencies: ["PrivateCamSegmentation"]),
        .testTarget(
            name: "PrivateCamSegmentationTests",
            dependencies: ["PrivateCamSegmentation"],
            resources: [.process("Fixtures")]
        )
    ]
)
