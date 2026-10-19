import CoreImage
import CoreVideo
import ImageIO
import XCTest
@testable import PrivateCamSegmentation

final class SegmentationTests: XCTestCase {
    func testMissingFrameReturnsNeutralFallbackWithRequestedSize() {
        let processor = BackgroundReplacementProcessor(quality: .fast)
        let result = processor.process(nil, fallbackSize: CGSize(width: 321, height: 241))

        XCTAssertTrue(result.usedNeutralFallback)
        XCTAssertEqual(result.image.width, 321)
        XCTAssertEqual(result.image.height, 241)
        XCTAssertNotNil(result.failureReason)
    }

    func testLicensedPortraitProducesSafeCompositeAndBlurOutput() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Portrait-CC0", withExtension: "jpg"))
        let source = try loadDownsampledImage(at: url, maximumDimension: 1280)
        let processor = BackgroundReplacementProcessor(quality: .fast)
        let result = processor.process(source, treatment: .blur(radius: 14))

        XCTAssertFalse(result.usedNeutralFallback, result.failureReason ?? "unexpected fallback")
        XCTAssertEqual(result.image.width, source.width)
        XCTAssertEqual(result.image.height, source.height)
        XCTAssertGreaterThanOrEqual(result.segmentationMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(result.compositingMilliseconds, 0)
        XCTAssertFalse(imagesEqual(source, result.image), "success output must not forward the original frame")
    }

    func testSolidBackgroundModeReturnsAFullSizeComposite() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Portrait-CC0", withExtension: "jpg"))
        let source = try loadDownsampledImage(at: url, maximumDimension: 640)
        let processor = BackgroundReplacementProcessor(quality: .balanced)
        let result = processor.process(source, treatment: .solid(BackgroundReplacementProcessor.neutralColor))

        XCTAssertFalse(result.usedNeutralFallback, result.failureReason ?? "unexpected fallback")
        XCTAssertEqual(result.image.width, source.width)
        XCTAssertEqual(result.image.height, source.height)
        XCTAssertFalse(imagesEqual(source, result.image))
    }

    func testRealtimeNV12BufferProcessingPreservesAdvertisedFormat() throws {
        let pool = try makeNV12Pool()
        let source = try makeNV12Buffer(from: CIImage(color: CIColor(red: 0.85, green: 0.12, blue: 0.08)), pool: pool)
        let processor = BackgroundReplacementProcessor(quality: .fast)
        let result = processor.process(pixelBuffer: source, outputPool: pool,
                                       treatment: .solid(BackgroundReplacementProcessor.neutralColor))

        XCTAssertFalse(result.usedNeutralFallback, result.failureReason ?? "unexpected fallback")
        XCTAssertFalse(result.pixelBuffer === source, "processed pipeline must allocate a distinct output buffer")
        XCTAssertEqual(CVPixelBufferGetWidth(result.pixelBuffer), 1280)
        XCTAssertEqual(CVPixelBufferGetHeight(result.pixelBuffer), 720)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(result.pixelBuffer), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertGreaterThanOrEqual(result.segmentationMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(result.compositingMilliseconds, 0)
    }

    func testRealtimeFaultInjectionReturnsNeutralNotSource() throws {
        let pool = try makeNV12Pool()
        let source = try makeNV12Buffer(from: CIImage(color: CIColor(red: 0.95, green: 0.03, blue: 0.04)), pool: pool)
        let processor = BackgroundReplacementProcessor(quality: .fast)
        for fault in [BackgroundProcessingFault.visionFailure, .invalidMaskDimensions, .compositingFailure] {
            let result = processor.process(pixelBuffer: source, outputPool: pool,
                                           treatment: .blur(radius: 24), fault: fault)
            XCTAssertTrue(result.usedNeutralFallback, "fault \(fault) should choose neutral output")
            XCTAssertNotNil(result.failureReason)
            XCTAssertFalse(result.pixelBuffer === source, "fault \(fault) forwarded source buffer")
            XCTAssertEqual(CVPixelBufferGetWidth(result.pixelBuffer), 1280)
            XCTAssertEqual(CVPixelBufferGetHeight(result.pixelBuffer), 720)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(result.pixelBuffer), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            let neutralChroma = try sampleChroma(result.pixelBuffer)
            let sourceChroma = try sampleChroma(source)
            XCTAssertLessThanOrEqual(abs(Int(neutralChroma.0) - 128), 4, "fallback Cb must be neutral")
            XCTAssertLessThanOrEqual(abs(Int(neutralChroma.1) - 128), 4, "fallback Cr must be neutral")
            XCTAssertGreaterThan(abs(Int(sourceChroma.0) - Int(neutralChroma.0)) + abs(Int(sourceChroma.1) - Int(neutralChroma.1)), 40,
                                 "fallback pixels must differ from the synthetic raw marker")
        }
    }

    func testRealtimeSolidAndBlurModesProduceDifferentSafeBuffers() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Portrait-CC0", withExtension: "jpg"))
        let sourceImage = try loadDownsampledImage(at: url, maximumDimension: 1280)
        let pool = try makeNV12Pool()
        let source = try makeNV12Buffer(from: CIImage(cgImage: sourceImage), pool: pool)
        let processor = BackgroundReplacementProcessor(quality: .fast)
        let solid = processor.process(pixelBuffer: source, outputPool: pool,
            treatment: .solid(CIColor(red: 0.08, green: 0.72, blue: 0.18)))
        let blur = processor.process(pixelBuffer: source, outputPool: pool, treatment: .blur(radius: 22))

        XCTAssertFalse(solid.usedNeutralFallback, solid.failureReason ?? "solid unexpectedly fell back")
        XCTAssertFalse(blur.usedNeutralFallback, blur.failureReason ?? "blur unexpectedly fell back")
        XCTAssertFalse(solid.pixelBuffer === source)
        XCTAssertFalse(blur.pixelBuffer === source)
        let solidChroma = try sampleChroma(solid.pixelBuffer)
        let blurChroma = try sampleChroma(blur.pixelBuffer)
        XCTAssertTrue(solidChroma.0 != blurChroma.0 || solidChroma.1 != blurChroma.1,
                      "configured solid color should reach compositor separately from blur mode")
    }

    func testSoftBlueProducesSafeCompositeDistinctFromSourceAndSolid() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Portrait-CC0", withExtension: "jpg"))
        let sourceImage = try loadDownsampledImage(at: url, maximumDimension: 1280)
        let pool = try makeNV12Pool()
        let source = try makeNV12Buffer(from: CIImage(cgImage: sourceImage), pool: pool)
        let processor = BackgroundReplacementProcessor(quality: .fast)
        let blue = processor.process(pixelBuffer: source, outputPool: pool, treatment: .softBlue)
        let neutral = processor.process(pixelBuffer: source, outputPool: pool,
            treatment: .solid(BackgroundReplacementProcessor.neutralColor))
        XCTAssertFalse(blue.usedNeutralFallback, blue.failureReason ?? "Soft Blue unexpectedly fell back")
        XCTAssertFalse(blue.pixelBuffer === source)
        XCTAssertFalse(blue.pixelBuffer === neutral.pixelBuffer)
        XCTAssertNotEqual(try sampleChroma(blue.pixelBuffer).0, try sampleChroma(neutral.pixelBuffer).0)
    }

    func testCachedPhotoBackgroundProducesSafeComposite() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Portrait-CC0", withExtension: "jpg"))
        let sourceImage = try loadDownsampledImage(at: url, maximumDimension: 1280)
        let pool = try makeNV12Pool()
        let source = try makeNV12Buffer(from: CIImage(cgImage: sourceImage), pool: pool)
        let processor = BackgroundReplacementProcessor(quality: .fast)
        let treatment = BackgroundTreatment.photo(id: "fixture", url: url)
        let first = processor.process(pixelBuffer: source, outputPool: pool, treatment: treatment)
        let second = processor.process(pixelBuffer: source, outputPool: pool, treatment: treatment)
        XCTAssertFalse(first.usedNeutralFallback, first.failureReason ?? "photo background unexpectedly fell back")
        XCTAssertFalse(second.usedNeutralFallback, second.failureReason ?? "cached photo background unexpectedly fell back")
        XCTAssertFalse(first.pixelBuffer === source)
        XCTAssertFalse(second.pixelBuffer === source)
        XCTAssertEqual(CVPixelBufferGetWidth(first.pixelBuffer), 1280)
        XCTAssertEqual(CVPixelBufferGetHeight(first.pixelBuffer), 720)
    }

    func testMalformedPhotoBackgroundUsesNeutralFallbackInsteadOfSource() throws {
        let pool = try makeNV12Pool()
        let source = try makeNV12Buffer(from: CIImage(color: CIColor(red: 0.95, green: 0.02, blue: 0.03)), pool: pool)
        let broken = FileManager.default.temporaryDirectory.appendingPathComponent("aurevix-invalid-\(UUID().uuidString).jpg")
        try Data("not an image".utf8).write(to: broken)
        defer { try? FileManager.default.removeItem(at: broken) }
        let processor = BackgroundReplacementProcessor(quality: .fast)
        let result = processor.process(pixelBuffer: source, outputPool: pool,
            treatment: .photo(id: "broken", url: broken))
        XCTAssertTrue(result.usedNeutralFallback)
        XCTAssertNotNil(result.failureReason)
        XCTAssertFalse(result.pixelBuffer === source)
        XCTAssertEqual(CVPixelBufferGetWidth(result.pixelBuffer), 1280)
        let chroma = try sampleChroma(result.pixelBuffer)
        XCTAssertLessThanOrEqual(abs(Int(chroma.0) - 128), 4)
        XCTAssertLessThanOrEqual(abs(Int(chroma.1) - 128), 4)
    }

    func testOutputPoolPressureUsesCachedNeutralFallback() throws {
        let pool = try makeNV12Pool()
        let source = try makeNV12Buffer(from: CIImage(color: CIColor(red: 0.9, green: 0.05, blue: 0.02)), pool: pool)
        let processor = BackgroundReplacementProcessor(quality: .fast)
        var heldOutputs: [CVPixelBuffer] = []
        var observedFallback = false
        for _ in 0..<20 {
            let result = processor.process(pixelBuffer: source, outputPool: pool,
                                           treatment: .blur(radius: 18))
            heldOutputs.append(result.pixelBuffer)
            if result.usedNeutralFallback {
                observedFallback = true
                XCTAssertFalse(result.pixelBuffer === source)
                XCTAssertEqual(CVPixelBufferGetWidth(result.pixelBuffer), 1280)
                let chroma = try sampleChroma(result.pixelBuffer)
                XCTAssertLessThanOrEqual(abs(Int(chroma.0) - 128), 4)
                XCTAssertLessThanOrEqual(abs(Int(chroma.1) - 128), 4)
            }
        }
        XCTAssertTrue(observedFallback, "bounded output-pool pressure must select neutral fallback")
        XCTAssertEqual(heldOutputs.count, 20)
    }

    func testMalformedSourceDimensionsReturnAdvertisedNeutralBuffer() throws {
        let outputPool = try makeNV12Pool()
        let malformedAttributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: 640,
            kCVPixelBufferHeightKey: 480,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var malformed: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 480,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, malformedAttributes as CFDictionary, &malformed), kCVReturnSuccess)
        let processor = BackgroundReplacementProcessor(quality: .fast)
        let badSource = try XCTUnwrap(malformed)
        let result = processor.process(pixelBuffer: badSource, outputPool: outputPool,
                                       treatment: .solid(BackgroundReplacementProcessor.neutralColor))

        XCTAssertTrue(result.usedNeutralFallback)
        XCTAssertFalse(result.pixelBuffer === badSource)
        XCTAssertEqual(CVPixelBufferGetWidth(result.pixelBuffer), 1280)
        XCTAssertEqual(CVPixelBufferGetHeight(result.pixelBuffer), 720)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(result.pixelBuffer), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let chroma = try sampleChroma(result.pixelBuffer)
        XCTAssertLessThanOrEqual(abs(Int(chroma.0) - 128), 4)
        XCTAssertLessThanOrEqual(abs(Int(chroma.1) - 128), 4)
    }

    private func makeNV12Pool() throws -> CVPixelBufferPool {
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: 1280,
            kCVPixelBufferHeightKey: 720,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var pool: CVPixelBufferPool?
        XCTAssertEqual(CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool), kCVReturnSuccess)
        return try XCTUnwrap(pool)
    }

    private func makeNV12Buffer(from image: CIImage, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer), kCVReturnSuccess)
        let source = try XCTUnwrap(buffer)
        let cropped = image.cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        CIContext().render(cropped, to: source, bounds: cropped.extent,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
        return source
    }

    private func sampleChroma(_ buffer: CVPixelBuffer) throws -> (UInt8, UInt8) {
        guard CVPixelBufferGetPlaneCount(buffer) >= 2 else { throw NSError(domain: "SegmentationTests", code: 1) }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            throw NSError(domain: "SegmentationTests", code: 2)
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        return (bytes[0], bytes[1])
    }

    private func imagesEqual(_ left: CGImage, _ right: CGImage) -> Bool {
        guard left.width == right.width, left.height == right.height,
              let leftData = left.dataProvider?.data as Data?,
              let rightData = right.dataProvider?.data as Data? else { return false }
        return leftData == rightData
    }
}
