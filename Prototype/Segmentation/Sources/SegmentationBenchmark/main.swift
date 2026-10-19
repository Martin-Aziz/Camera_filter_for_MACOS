import AppKit
import CoreImage
import CoreVideo
import Darwin
import Foundation
import PrivateCamSegmentation

struct Options {
    let input: URL
    let outputDirectory: URL
    let iterations: Int
    let quality: SegmentationQuality?
    let maskPixelFormat: OSType
    let blurModel: BackgroundBlurModel
    let edgeRefine: CGFloat
    let blurRadius: CGFloat
    let treatmentName: String
    let photoURL: URL?
}

struct RealtimeTiming {
    let segmentation: Double
    let compositing: Double
    let fallback: Bool
    let failureReason: String?
}

@main
enum SegmentationBenchmark {
    static func main() throws {
        setbuf(stdout, nil)
        let options = try parseOptions()
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        let decoded = try loadDownsampledImage(at: options.input, maximumDimension: 1280)
        let source = try cameraSizedFrame(decoded)
        let csvURL = options.outputDirectory.appendingPathComponent("processing-benchmark.csv")
        var csv = "quality,iteration,segmentation_ms,compositing_ms,total_ms,fallback\n"
        var realtimeCSV = "quality,iteration,segmentation_ms,compositing_ms,total_ms,fallback\n"
        let nv12Pool = try makeNV12Pool()
        let nv12Source = try makeNV12Buffer(from: source, pool: nv12Pool)

        let selectedQualities = options.quality.map { [$0] } ?? SegmentationQuality.allCases
        for quality in selectedQualities {
            let treatment: BackgroundTreatment = options.photoURL.map { .photo(id: options.treatmentName, url: $0) }
                ?? (options.treatmentName == "soft-blue" ? .softBlue : .blur(radius: options.blurRadius))
            let processor = BackgroundReplacementProcessor(quality: quality,
                maskPixelFormat: options.maskPixelFormat, blurModel: options.blurModel,
                maskFeatherRadius: options.edgeRefine)
            print("fixture_configuration quality=\(quality.rawValue) treatment=\(options.treatmentName) requested_mask=\(String(format: "0x%08x", options.maskPixelFormat)) actual_mask=\(String(format: "0x%08x", processor.maskPixelFormat)) blur_model=\(processor.blurModel.rawValue) edge_refine=\(processor.maskFeatherRadius) radius=\(options.blurRadius)")
            var results: [BackgroundProcessingResult] = []
            for index in 0..<(options.iterations + 3) {
                let result = processor.process(source, treatment: treatment)
                if index >= 3 {
                    results.append(result)
                    csv += "\(quality.rawValue),\(index - 2),\(format(result.segmentationMilliseconds)),\(format(result.compositingMilliseconds)),\(format(result.segmentationMilliseconds + result.compositingMilliseconds)),\(result.usedNeutralFallback)\n"
                }
            }
            guard let final = results.last, !final.usedNeutralFallback else {
                throw NSError(domain: "PrivateCamSegmentationBenchmark", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "\(quality.rawValue) processing fell back: \(results.last?.failureReason ?? "no result")"])
            }
            try savePNG(final.image, to: options.outputDirectory.appendingPathComponent("after-\(quality.rawValue).png"))
            try saveSideBySide(before: source, after: final.image,
                               to: options.outputDirectory.appendingPathComponent("before-after-\(quality.rawValue).png"))
            printSummary(quality: quality, results: results)

            let realtimeProcessor = BackgroundReplacementProcessor(quality: quality,
                maskPixelFormat: options.maskPixelFormat, blurModel: options.blurModel,
                maskFeatherRadius: options.edgeRefine)
            var realtimeResults: [RealtimeTiming] = []
            var realtimeFinalBuffer: CVPixelBuffer?
            var realtimeDiagnostics: String?
            for index in 0..<(options.iterations + 3) {
                let result = realtimeProcessor.process(pixelBuffer: nv12Source, outputPool: nv12Pool,
                                                       treatment: treatment)
                if index >= 3 {
                    realtimeResults.append(RealtimeTiming(segmentation: result.segmentationMilliseconds,
                        compositing: result.compositingMilliseconds, fallback: result.usedNeutralFallback,
                        failureReason: result.failureReason))
                    realtimeFinalBuffer = result.pixelBuffer
                    realtimeDiagnostics = result.processingDiagnostics
                    realtimeCSV += "\(quality.rawValue),\(index - 2),\(format(result.segmentationMilliseconds)),\(format(result.compositingMilliseconds)),\(format(result.segmentationMilliseconds + result.compositingMilliseconds)),\(result.usedNeutralFallback)\n"
                }
            }
            guard realtimeResults.last?.fallback == false, let realtimeFinalBuffer,
                  let realtimeImage = CIContext().createCGImage(CIImage(cvPixelBuffer: realtimeFinalBuffer),
                    from: CGRect(x: 0, y: 0, width: 1280, height: 720)) else {
                if let failure = realtimeResults.last?.failureReason {
                    print("integrated_buffer_path quality=\(quality.rawValue) failure_reason=\(failure)")
                }
                throw NSError(domain: "PrivateCamSegmentationBenchmark", code: 9,
                              userInfo: [NSLocalizedDescriptionKey: "\(quality.rawValue) NV12 processing produced fallback or no render"])
            }
            try savePNG(realtimeImage, to: options.outputDirectory.appendingPathComponent("integrated-after-\(quality.rawValue).png"))
            if let realtimeDiagnostics { print("integrated_buffer_diagnostics quality=\(quality.rawValue) \(realtimeDiagnostics)") }
            try saveSideBySide(before: source, after: realtimeImage,
                               to: options.outputDirectory.appendingPathComponent("integrated-before-after-\(quality.rawValue).png"))
            let solidResult = realtimeProcessor.process(pixelBuffer: nv12Source, outputPool: nv12Pool,
                treatment: .solid(BackgroundReplacementProcessor.neutralColor))
            guard let solidImage = CIContext().createCGImage(CIImage(cvPixelBuffer: solidResult.pixelBuffer),
                from: CGRect(x: 0, y: 0, width: 1280, height: 720)) else {
                throw NSError(domain: "PrivateCamSegmentationBenchmark", code: 12,
                              userInfo: [NSLocalizedDescriptionKey: "Could not render integrated solid sample"])
            }
            try savePNG(solidImage, to: options.outputDirectory.appendingPathComponent("integrated-solid-\(quality.rawValue).png"))
            printRealtimeSummary(quality: quality, results: realtimeResults)
        }

        try csv.write(to: csvURL, atomically: true, encoding: .utf8)
        try realtimeCSV.write(to: options.outputDirectory.appendingPathComponent("integrated-processing-benchmark.csv"), atomically: true, encoding: .utf8)
        print("source_dimensions=\(source.width)x\(source.height) iterations=\(options.iterations) warmup=3 output=\(options.outputDirectory.path)")
    }

    private static func parseOptions() throws -> Options {
        let args = CommandLine.arguments
        func value(_ flag: String, default defaultValue: String? = nil) throws -> String {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
                if let defaultValue { return defaultValue }
                throw NSError(domain: "PrivateCamSegmentationBenchmark", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Missing \(flag) <value>"])
            }
            return args[index + 1]
        }
        let input = URL(fileURLWithPath: try value("--input"))
        let output = URL(fileURLWithPath: try value("--output-dir"))
        let iterations = Int(try value("--iterations", default: "20")) ?? 20
        let qualityName = try value("--quality", default: "all")
        let quality = qualityName == "all" ? nil : SegmentationQuality(rawValue: qualityName)
        guard qualityName == "all" || quality != nil else {
            throw NSError(domain: "PrivateCamSegmentationBenchmark", code: 13,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown quality \(qualityName); choose fast, balanced, accurate, or all"])
        }
        guard iterations > 0 else { throw NSError(domain: "PrivateCamSegmentationBenchmark", code: 3) }
        let precisionName = try value("--precision", default: "8")
        let maskPixelFormat: OSType
        switch precisionName {
        case "8": maskPixelFormat = kCVPixelFormatType_OneComponent8
        case "16half": maskPixelFormat = kCVPixelFormatType_OneComponent16Half
        default: throw NSError(domain: "PrivateCamSegmentationBenchmark", code: 14,
            userInfo: [NSLocalizedDescriptionKey: "Unknown --precision \(precisionName); choose 8 or 16half"])
        }
        let modelName = try value("--blur-model", default: BackgroundBlurModel.gaussianComposite.rawValue)
        guard let blurModel = BackgroundBlurModel(rawValue: modelName) else {
            throw NSError(domain: "PrivateCamSegmentationBenchmark", code: 15,
                userInfo: [NSLocalizedDescriptionKey: "Unknown --blur-model \(modelName)"])
        }
        let edgeRefine = CGFloat(Double(try value("--edge-refine", default: "1.1")) ?? 1.1)
        let blurRadius = CGFloat(Double(try value("--radius", default: "18")) ?? 18)
        let treatmentArgument = try value("--treatment", default: "blur")
        guard edgeRefine >= 0, edgeRefine <= 2, blurRadius >= 0, blurRadius <= 48 else {
            throw NSError(domain: "PrivateCamSegmentationBenchmark", code: 16,
                userInfo: [NSLocalizedDescriptionKey: "--edge-refine must be 0...2 and --radius 0...48"])
        }
        let photoURL: URL?
        let treatmentName: String
        if treatmentArgument == "blur" || treatmentArgument == "soft-blue" {
            treatmentName = treatmentArgument
            photoURL = nil
        } else if treatmentArgument.hasPrefix("photo:") {
            let path = String(treatmentArgument.dropFirst("photo:".count))
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
                throw NSError(domain: "PrivateCamSegmentationBenchmark", code: 17,
                              userInfo: [NSLocalizedDescriptionKey: "Photo treatment path does not exist"])
            }
            treatmentName = "photo"
            photoURL = URL(fileURLWithPath: path)
        } else {
            throw NSError(domain: "PrivateCamSegmentationBenchmark", code: 18,
                          userInfo: [NSLocalizedDescriptionKey: "--treatment must be blur, soft-blue, or photo:<path>"])
        }
        return Options(input: input, outputDirectory: output, iterations: iterations, quality: quality,
            maskPixelFormat: maskPixelFormat, blurModel: blurModel, edgeRefine: edgeRefine, blurRadius: blurRadius,
            treatmentName: treatmentName, photoURL: photoURL)
    }

    private static func savePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "PrivateCamSegmentationBenchmark", code: 4)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "PrivateCamSegmentationBenchmark", code: 5) }
    }

    private static func cameraSizedFrame(_ image: CGImage) throws -> CGImage {
        let width = min(1280, image.width)
        let height = min(720, image.height)
        let rect = CGRect(
            x: CGFloat(image.width - width) / 2,
            y: CGFloat(image.height - height) / 2,
            width: CGFloat(width),
            height: CGFloat(height)
        )
        let cropped = CIImage(cgImage: image).cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        guard let result = CIContext(options: [.cacheIntermediates: false]).createCGImage(
            cropped,
            from: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        ) else {
            throw NSError(domain: "PrivateCamSegmentationBenchmark", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "Could not prepare a 1280x720 benchmark frame"])
        }
        return result
    }

    private static func saveSideBySide(before: CGImage, after: CGImage, to url: URL) throws {
        let tileWidth: CGFloat = 640
        let tileHeight = tileWidth * CGFloat(before.height) / CGFloat(before.width)
        func tile(_ image: CGImage, x: CGFloat) -> CIImage {
            CIImage(cgImage: image)
                .transformed(by: CGAffineTransform(scaleX: tileWidth / CGFloat(image.width), y: tileHeight / CGFloat(image.height)))
                .transformed(by: CGAffineTransform(translationX: x, y: 0))
        }
        let canvas = CGRect(x: 0, y: 0, width: tileWidth * 2, height: tileHeight)
        let image = tile(before, x: 0).composited(over: CIImage(color: .black).cropped(to: canvas))
            .composited(over: CIImage(color: .clear).cropped(to: canvas))
        let combined = tile(after, x: tileWidth).composited(over: image).cropped(to: canvas)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(combined, from: canvas),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "PrivateCamSegmentationBenchmark", code: 6)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "PrivateCamSegmentationBenchmark", code: 7) }
    }

    private static func printSummary(quality: SegmentationQuality, results: [BackgroundProcessingResult]) {
        let segmentation = results.map(\.segmentationMilliseconds).sorted()
        let compositing = results.map(\.compositingMilliseconds).sorted()
        let total = results.map { $0.segmentationMilliseconds + $0.compositingMilliseconds }.sorted()
        print("quality=\(quality.rawValue) segmentation_p50_ms=\(format(percentile(segmentation, 0.50))) segmentation_p95_ms=\(format(percentile(segmentation, 0.95))) composite_p50_ms=\(format(percentile(compositing, 0.50))) composite_p95_ms=\(format(percentile(compositing, 0.95))) total_p50_ms=\(format(percentile(total, 0.50))) total_p95_ms=\(format(percentile(total, 0.95))) fallback_count=\(results.filter(\.usedNeutralFallback).count)")
    }

    private static func printRealtimeSummary(quality: SegmentationQuality, results: [RealtimeTiming]) {
        let segmentation = results.map(\.segmentation).sorted()
        let compositing = results.map(\.compositing).sorted()
        let total = results.map { $0.segmentation + $0.compositing }.sorted()
        print("integrated_buffer_path quality=\(quality.rawValue) segmentation_p50_ms=\(format(percentile(segmentation, 0.50))) segmentation_p95_ms=\(format(percentile(segmentation, 0.95))) segmentation_p99_ms=\(format(percentile(segmentation, 0.99))) composite_p50_ms=\(format(percentile(compositing, 0.50))) composite_p95_ms=\(format(percentile(compositing, 0.95))) composite_p99_ms=\(format(percentile(compositing, 0.99))) total_p50_ms=\(format(percentile(total, 0.50))) total_p95_ms=\(format(percentile(total, 0.95))) total_p99_ms=\(format(percentile(total, 0.99))) fallback_count=\(results.filter(\.fallback).count)")
    }

    private static func makeNV12Pool() throws -> CVPixelBufferPool {
        let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: 1280, kCVPixelBufferHeightKey: 720,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else { throw NSError(domain: "PrivateCamSegmentationBenchmark", code: 10) }
        return pool
    }

    private static func makeNV12Buffer(from image: CGImage, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let buffer else { throw NSError(domain: "PrivateCamSegmentationBenchmark", code: 11) }
        CIContext().render(CIImage(cgImage: image), to: buffer,
                           bounds: CGRect(x: 0, y: 0, width: 1280, height: 720),
                           colorSpace: CGColorSpaceCreateDeviceRGB())
        return buffer
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    private static func format(_ value: Double) -> String { String(format: "%.3f", value) }
}
