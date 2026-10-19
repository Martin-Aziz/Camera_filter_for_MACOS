import CoreImage
import CoreVideo
import ImageIO
import Vision
import XCTest
@testable import PrivateCamSegmentation

final class SegmentationTests: XCTestCase {
    func testSkinPresetsIntensityBoundsAndPersistence() {
        XCTAssertEqual(SkinRefinementConfiguration(preset: .off).effectiveIntensity, 0)
        XCTAssertEqual(SkinRefinementConfiguration(preset: .subtle).effectiveIntensity, 0.16, accuracy: 0.001)
        XCTAssertEqual(SkinRefinementConfiguration(preset: .refined).effectiveIntensity, 0.30, accuracy: 0.001)
        XCTAssertEqual(SkinRefinementConfiguration(preset: .custom, intensity: 9).effectiveIntensity, 0.4)
        XCTAssertEqual(SkinRefinementConfiguration(preset: .custom, intensity: -2).effectiveIntensity, 0)
        let suite = "AurevixCamTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        SkinRefinementConfiguration(preset: .refined, intensity: 0.73).write(to: defaults)
        let restored = SkinRefinementConfiguration.read(from: defaults)
        XCTAssertEqual(restored.preset, .refined)
        XCTAssertEqual(restored.intensity, 0.4)
        XCTAssertEqual(SkinRefinementConfiguration.read(from: UserDefaults(suiteName: suite)).preset, .refined)
    }

    func testSkinRetouchOffIsIdentityAndEnabledChangesDetectedSkin() throws {
        // Supplied package portrait is an offline test fixture; it is not an app resource.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SkinTest-medium-brown", withExtension: "png"))
        let source = try loadDownsampledImage(at: url, maximumDimension: 640)
        let input = CIImage(cgImage: source)
        XCTAssertTrue(NaturalSkinRetouch.apply(to: input, intensity: 0) === input,
                      "Off must return the untouched Core Image input")
        let context = CIContext()
        let subtle = NaturalSkinRetouch.apply(to: input, intensity: 0.16)
        let refined = NaturalSkinRetouch.apply(to: input, intensity: 0.30)
        let subtleRendered = try XCTUnwrap(context.createCGImage(subtle, from: subtle.extent))
        let refinedRendered = try XCTUnwrap(context.createCGImage(refined, from: refined.extent))
        XCTAssertFalse(imagesEqual(source, subtleRendered), "Subtle should gently refine detected face skin")
        XCTAssertFalse(imagesEqual(subtleRendered, refinedRendered), "Refined must be distinct and stronger than Subtle")
    }

    func testSkinMaskContextAllocationFailureNeverBecomesImageShapedMask() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SkinTest-medium-brown", withExtension: "png"))
        let source = try loadDownsampledImage(at: url, maximumDimension: 480)
        let input = CIImage(cgImage: source)
        let failedMask = NaturalSkinRetouch.diagnosticMask(for: input, intensity: 0.30,
                                                            failGrayscaleContextAllocation: true)
        XCTAssertNil(failedMask, "failed grayscale mask allocation must return nil, never the source frame")
        let output = NaturalSkinRetouch.applyForCalibration(to: input, intensity: 0.30,
            noiseLevel: 0.03, sharpness: 0.65, blendScale: 1,
            failGrayscaleContextAllocation: true)
        XCTAssertTrue(output === input, "a missing mask should retain the existing safe no-op path")
    }

    func testApprovedSkinSettingsAreUsedByProductionPresets() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SkinTest-medium-brown", withExtension: "png"))
        let source = CIImage(cgImage: try loadDownsampledImage(at: url, maximumDimension: 480))
        let context = CIContext()
        for (intensity, approvedBlend) in [(0.16, 1.0), (0.30, 1.08)] {
            let production = NaturalSkinRetouch.apply(to: source, intensity: intensity)
            let approved = NaturalSkinRetouch.applyForCalibration(to: source, intensity: intensity,
                noiseLevel: 0.06, sharpness: 0.82, blendScale: approvedBlend)
            let productionImage = try XCTUnwrap(context.createCGImage(production, from: production.extent))
            let approvedImage = try XCTUnwrap(context.createCGImage(approved, from: approved.extent))
            XCTAssertTrue(imagesEqual(productionImage, approvedImage),
                "production intensity \(intensity) must use the approved denoise and blend settings")
        }
    }

    func testSkinRetouchLeavesNonFaceInputAlone() throws {
        let blank = CIImage(color: CIColor(red: 0.25, green: 0.4, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 240))
        let output = NaturalSkinRetouch.apply(to: blank, intensity: 0.4)
        let context = CIContext()
        let before = try XCTUnwrap(context.createCGImage(blank, from: blank.extent))
        let after = try XCTUnwrap(context.createCGImage(output, from: output.extent))
        XCTAssertTrue(imagesEqual(before, after), "No detected face should leave the image unchanged")
    }

    func testSkinRetouchStrengthIsSmoothlyMonotonicAcrossFourSyntheticPortraits() throws {
        let names = ["SkinTest-medium-brown", "SkinTest-light-textured", "SkinTest-deep-lowkey", "SkinTest-light-medium"]
        let strengths: [Double] = [0.10, 0.16, 0.20, 0.30, 0.40]
        let context = CIContext()
        for name in names {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png"))
            let source = try loadDownsampledImage(at: url, maximumDimension: 480)
            let input = CIImage(cgImage: source)
            let mask = try XCTUnwrap(NaturalSkinRetouch.diagnosticMask(for: input, intensity: 0.4))
            XCTAssertEqual(mask.extent, input.extent, "\(name): diagnostic mask must align to the frame")
            let maskImage = try XCTUnwrap(context.createCGImage(mask, from: mask.extent))
            XCTAssertGreaterThan(maskImage.pixelLumaAverage, 0.01, "\(name): mask should cover detected facial skin")
            XCTAssertLessThan(maskImage.pixelLumaAverage, 0.5, "\(name): mask should remain spatially selective")
            var prior = -Double.infinity
            for strength in strengths {
                let output = NaturalSkinRetouch.apply(to: input, intensity: strength)
                let rendered = try XCTUnwrap(context.createCGImage(output, from: output.extent))
                let difference = meanAbsoluteDifference(source, rendered)
                XCTAssertGreaterThan(difference, prior, "\(name): strength \(strength) should increase monotonically")
                prior = difference
            }
        }
    }

    func testSkinRetouchHandlesTwoFacesAndShiftedFrameIndependently() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SkinTest-medium-brown", withExtension: "png"))
        let face = try loadDownsampledImage(at: url, maximumDimension: 512)
        let width = face.width, height = face.height
        let twoFaceContext = CGContext(data: nil, width: width * 2, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        twoFaceContext.draw(face, in: CGRect(x: 0, y: 0, width: width, height: height))
        twoFaceContext.draw(face, in: CGRect(x: width, y: 0, width: width, height: height))
        let multiFace = try XCTUnwrap(twoFaceContext.makeImage())
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: multiFace, options: [:]).perform([request])
        XCTAssertGreaterThanOrEqual(request.results?.count ?? 0, 2, "fixture composition should exercise two detected faces")
        let multiInput = CIImage(cgImage: multiFace)
        let multiOutput = NaturalSkinRetouch.apply(to: multiInput, intensity: 0.16)
        let renderedMulti = try XCTUnwrap(CIContext().createCGImage(multiOutput, from: multiOutput.extent))
        XCTAssertFalse(imagesEqual(multiFace, renderedMulti), "both detected faces should be eligible for refinement")

        let shiftedContext = CGContext(data: nil, width: width + 64, height: height, bitsPerComponent: 8,
            bytesPerRow: (width + 64) * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        shiftedContext.setFillColor(CGColor(gray: 0.4, alpha: 1))
        shiftedContext.fill(CGRect(x: 0, y: 0, width: width + 64, height: height))
        shiftedContext.draw(face, in: CGRect(x: 64, y: 0, width: width, height: height))
        let shifted = try XCTUnwrap(shiftedContext.makeImage())
        let shiftedInput = CIImage(cgImage: shifted)
        let shiftedOutput = NaturalSkinRetouch.apply(to: shiftedInput, intensity: 0.16)
        XCTAssertEqual(shiftedOutput.extent, shiftedInput.extent, "frame-to-frame movement must not reuse stale mask geometry")
    }

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
        for fault in [BackgroundProcessingFault.visionFailure, .noMask, .invalidMaskDimensions, .compositingFailure] {
            let result = processor.process(pixelBuffer: source, outputPool: pool,
                                           treatment: .blur(radius: 24), fault: fault)
            XCTAssertTrue(result.usedNeutralFallback, "fault \(fault) should choose neutral output")
            XCTAssertNotNil(result.failureReason)
            if fault == .invalidMaskDimensions {
                XCTAssertTrue(result.failureReason?.contains("mask=") == true)
                XCTAssertTrue(result.failureReason?.contains("Y=1280x720") == true)
                XCTAssertTrue(result.failureReason?.contains("quality=fast revision=") == true)
            }
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

    func testMaskAlignmentAcceptsReducedResolutionAndNonzeroOrigin() throws {
        let destination = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let mask = CIImage(color: .white).cropped(to: CGRect(x: 13, y: -7, width: 256, height: 192))
        let aligned = try XCTUnwrap(SegmentationMaskGeometry.align(mask, to: destination))
        XCTAssertEqual(aligned.image.extent, destination)
        XCTAssertEqual(aligned.transform.tx, -65, accuracy: 0.001)
        XCTAssertEqual(aligned.transform.ty, 26.25, accuracy: 0.001)
        XCTAssertNil(SegmentationMaskGeometry.align(CIImage.empty(), to: destination))
        XCTAssertNil(SegmentationMaskGeometry.align(mask, to: .zero))
        let malformed = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 100))
        XCTAssertNil(SegmentationMaskGeometry.align(malformed, to: destination))
    }

    func testRealtimeQualityResolutionAndNV12RangeMatrix() throws {
        let cases: [(Int, Int)] = [(640, 480), (1280, 720), (1920, 1080), (480, 640)]
        for (width, height) in cases {
            for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                           kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] {
                let pool = try makePool(width: width, height: height, format: format)
                let source = try makeBuffer(from: CIImage(color: CIColor(red: 0.56, green: 0.35, blue: 0.27)), pool: pool)
                for quality in SegmentationQuality.allCases {
                    let result = BackgroundReplacementProcessor(quality: quality).process(pixelBuffer: source,
                        outputPool: pool, treatment: .solid(BackgroundReplacementProcessor.neutralColor))
                    XCTAssertFalse(result.usedNeutralFallback,
                        "\(quality.rawValue) \(width)x\(height) format=0x\(String(format, radix: 16)): \(result.failureReason ?? "") \(result.processingDiagnostics ?? "")")
                    XCTAssertEqual(CVPixelBufferGetWidth(result.pixelBuffer), width)
                    XCTAssertEqual(CVPixelBufferGetHeight(result.pixelBuffer), height)
                    XCTAssertEqual(CVPixelBufferGetPixelFormatType(result.pixelBuffer), format)
                }
            }
        }
    }

    func testRealtimeBGRAAndMalformedMaskFallback() throws {
        let pool = try makePool(width: 640, height: 480, format: kCVPixelFormatType_32BGRA)
        let source = try makeBuffer(from: CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.3)), pool: pool)
        for quality in SegmentationQuality.allCases {
            let success = BackgroundReplacementProcessor(quality: quality).process(pixelBuffer: source,
                outputPool: pool, treatment: .solid(BackgroundReplacementProcessor.neutralColor))
            XCTAssertFalse(success.usedNeutralFallback, "\(quality.rawValue): \(success.failureReason ?? "")")
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(success.pixelBuffer), kCVPixelFormatType_32BGRA)
        }
        let malformed = BackgroundReplacementProcessor(quality: .fast).process(pixelBuffer: source,
            outputPool: pool, treatment: .solid(BackgroundReplacementProcessor.neutralColor), fault: .invalidMaskDimensions)
        XCTAssertTrue(malformed.usedNeutralFallback)
        XCTAssertNotNil(malformed.failureReason)
        XCTAssertFalse(malformed.pixelBuffer === source)
    }

    func testRepeatedAndChangingFrameDimensionsReuseProcessorSafely() throws {
        let processor = BackgroundReplacementProcessor(quality: .accurate)
        for (width, height) in [(640, 480), (1280, 720), (640, 480), (1920, 1080), (480, 640)] {
            let pool = try makePool(width: width, height: height,
                                    format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            let source = try makeBuffer(from: CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6)), pool: pool)
            let result = processor.process(pixelBuffer: source, outputPool: pool,
                treatment: .solid(BackgroundReplacementProcessor.neutralColor))
            XCTAssertFalse(result.usedNeutralFallback,
                "\(width)x\(height): \(result.failureReason ?? "") \(result.processingDiagnostics ?? "")")
            XCTAssertEqual(CVPixelBufferGetWidth(result.pixelBuffer), width)
            XCTAssertEqual(CVPixelBufferGetHeight(result.pixelBuffer), height)
        }
    }

    private func makeNV12Pool() throws -> CVPixelBufferPool {
        try makePool(width: 1280, height: 720, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    private func makePool(width: Int, height: Int, format: OSType) throws -> CVPixelBufferPool {
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var pool: CVPixelBufferPool?
        XCTAssertEqual(CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool), kCVReturnSuccess)
        return try XCTUnwrap(pool)
    }

    private func makeNV12Buffer(from image: CIImage, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        try makeBuffer(from: image, pool: pool)
    }

    private func makeBuffer(from image: CIImage, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer), kCVReturnSuccess)
        let source = try XCTUnwrap(buffer)
        let cropped = image.cropped(to: CGRect(x: 0, y: 0,
            width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source)))
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

    private func meanAbsoluteDifference(_ left: CGImage, _ right: CGImage) -> Double {
        guard left.width == right.width, left.height == right.height else { return 0 }
        let width = left.width, height = left.height
        var a = [UInt8](repeating: 0, count: width * height * 4)
        var b = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        a.withUnsafeMutableBytes { raw in
            if let context = CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) { context.draw(left, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        }
        b.withUnsafeMutableBytes { raw in
            if let context = CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) { context.draw(right, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        }
        var total = 0.0
        for i in stride(from: 0, to: a.count, by: 4) {
            let red = Double(abs(Int(a[i]) - Int(b[i])))
            let green = Double(abs(Int(a[i + 1]) - Int(b[i + 1])))
            let blue = Double(abs(Int(a[i + 2]) - Int(b[i + 2])))
            total += (red + green + blue) / 3
        }
        return total / Double(width * height)
    }
}

private extension CGImage {
    var pixelLumaAverage: Double {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            if let context = CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return stride(from: 0, to: bytes.count, by: 4).reduce(0.0) { $0 + Double(bytes[$1]) / 255 } / Double(width * height)
    }
}
