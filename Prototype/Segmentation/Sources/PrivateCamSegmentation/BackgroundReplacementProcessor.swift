import CoreImage
import CoreVideo
import ImageIO
import Vision
import Foundation
import os

private let segmentationLogger = Logger(subsystem: "com.martinaziz.privatecam", category: "Segmentation")
public enum NaturalSkinRetouch {
    /// Deterministic fault hook for offline verification of mask-allocation failure.
    /// Production callers should use `apply` and `diagnosticMask`.
    public static func diagnosticMask(for image: CIImage, intensity: Double,
                                      failGrayscaleContextAllocation: Bool) -> CIImage? {
        makeMask(for: image, intensity: intensity,
                 failGrayscaleContextAllocation: failGrayscaleContextAllocation)
    }

    /// Returns a grayscale diagnostic mask with feature exclusions and feathered face boundaries.
    /// The returned mask uses the same single, continuous strength mapping as `apply`.
    public static func diagnosticMask(for image: CIImage, intensity: Double) -> CIImage? {
        makeMask(for: image, intensity: intensity)
    }

    /// Smooths facial skin with Core Image noise reduction, then blends that result
    /// through one strength-weighted, feathered skin mask. Landmark regions for
    /// eyes, brows, lips and nose remain protected.
    public static func apply(to image: CIImage, intensity: Double) -> CIImage {
        apply(to: image, intensity: intensity, noiseLevel: 0.06, sharpness: 0.82,
              blendScale: blendScale(for: min(max(intensity, 0), 0.4)))
    }

    /// Applies subtle face-local exposure, warmth, and shadow lift. Facial skin
    /// landmarks provide the mask; eyes, brows, lips and nose stay excluded.
    public static func applyLightAndTone(to image: CIImage, intensity: Double) -> CIImage {
        let amount = min(max(intensity, 0), 1)
        guard amount > 0, let mask = makeMask(for: image, intensity: 0.4) else { return image }
        let adjusted = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.16 * amount])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.015,
                kCIInputBrightnessKey: 0.012 * amount, kCIInputContrastKey: 1.0])
            .applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6650 + 250 * amount, y: 0)])
            .cropped(to: image.extent)
        let toneMask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.32, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.32, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.32, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ]).cropped(to: image.extent)
        return adjusted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: toneMask
        ]).cropped(to: image.extent)
    }

    /// Offline appearance calibration entry point. This keeps noise reduction
    /// and the final mask blend independently adjustable during evaluation.
    public static func applyForCalibration(to image: CIImage, intensity: Double,
                                           noiseLevel: Double, sharpness: Double,
                                           blendScale: Double,
                                           failGrayscaleContextAllocation: Bool = false) -> CIImage {
        apply(to: image, intensity: intensity, noiseLevel: noiseLevel,
              sharpness: sharpness, blendScale: blendScale,
              failGrayscaleContextAllocation: failGrayscaleContextAllocation)
    }

    private static func apply(to image: CIImage, intensity: Double, noiseLevel: Double,
                              sharpness: Double, blendScale: Double,
                              failGrayscaleContextAllocation: Bool = false) -> CIImage {
        let strength = min(max(intensity, 0), 0.4)
        guard strength > 0, image.extent.width > 0, image.extent.height > 0 else { return image }
        guard let mask = makeMask(for: image, intensity: strength,
                                  failGrayscaleContextAllocation: failGrayscaleContextAllocation) else { return image }
        let smoothed = image.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": min(max(noiseLevel, 0), 0.1),
            "inputSharpness": min(max(sharpness, 0), 1)
        ]).cropped(to: image.extent)
        let scaledMask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: blendScale, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: blendScale, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: blendScale, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ]).cropped(to: image.extent)
        return smoothed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: scaledMask
        ]).cropped(to: image.extent)
    }

    private static func makeMask(for image: CIImage, intensity: Double,
                                 failGrayscaleContextAllocation: Bool = false) -> CIImage? {
        let strength = min(max(intensity, 0), 0.4)
        guard strength > 0, image.extent.width > 0, image.extent.height > 0 else { return nil }
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        let analysisScale = min(1, 320 / max(image.extent.width, image.extent.height))
        let analysisImage = analysisScale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: analysisScale, y: analysisScale))
            : image
        do {
            try VNImageRequestHandler(ciImage: analysisImage, options: [:]).perform([request])
        } catch { return nil }
        guard let faces = request.results, !faces.isEmpty else { return nil }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard !failGrayscaleContextAllocation,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let opacity = maskOpacity(for: strength)
        for face in faces {
            let box = face.boundingBox
            let rect = CGRect(x: box.minX * extent.width, y: box.minY * extent.height,
                              width: box.width * extent.width, height: box.height * extent.height)
            context.setFillColor(gray: CGFloat(opacity), alpha: 1)
            if let contour = face.landmarks?.faceContour, contour.pointCount > 2 {
                let path = landmarkPath(contour, face: face, extent: extent)
                context.addPath(path); context.fillPath()
            } else {
                context.fillEllipse(in: rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.05))
            }
            context.setFillColor(gray: 0, alpha: 1)
            for region in [face.landmarks?.leftEye, face.landmarks?.rightEye, face.landmarks?.leftEyebrow,
                           face.landmarks?.rightEyebrow, face.landmarks?.outerLips, face.landmarks?.innerLips,
                           face.landmarks?.nose] .compactMap({ $0 }) {
                let path = landmarkPath(region, face: face, extent: extent)
                context.addPath(path); context.fillPath()
            }
        }
        guard let maskCG = context.makeImage() else { return nil }
        let mask = CIImage(cgImage: maskCG).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        // Feather only the geometric mask edge. Filter strength is not used to
        // shrink a blur radius, avoiding the old double attenuation.
        return mask.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.25])
            .cropped(to: extent)
    }

    private static func maskOpacity(for strength: Double) -> Double {
        let t = min(max(strength, 0) / 0.4, 1)
        guard t > 0 else { return 0 }
        // Smooth monotonic response gives the Subtle preset a perceptible mix
        // while retaining a bounded maximum at Custom 0.40.
        return 0.62 * (1 - exp(-1.3 * t)) / (1 - exp(-1.3))
    }

    private static func blendScale(for strength: Double) -> Double {
        let progress = min(max((strength - 0.16) / (0.30 - 0.16), 0), 1)
        return 1.0 + 0.08 * progress
    }

    private static func landmarkPath(_ region: VNFaceLandmarkRegion2D, face: VNFaceObservation, extent: CGRect) -> CGPath {
        let path = CGMutablePath()
        let box = face.boundingBox
        for (index, point) in region.normalizedPoints.enumerated() {
            let x = extent.minX + (box.minX + CGFloat(point.x) * box.width) * extent.width
            let y = extent.minY + (box.minY + CGFloat(point.y) * box.height) * extent.height
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.closeSubpath()
        return path
    }
}

public enum SegmentationQuality: String, CaseIterable {
    case fast
    case balanced
    case accurate

    fileprivate var visionValue: VNGeneratePersonSegmentationRequest.QualityLevel {
        switch self {
        case .fast: .fast
        case .balanced: .balanced
        case .accurate: .accurate
        }
    }
}

public enum BackgroundTreatment {
    case solid(CIColor)
    case blur(radius: CGFloat)
    case softBlue
    case photo(id: String, url: URL)
}

public enum BackgroundBlurModel: String, CaseIterable {
    /// Blur a background image and composite it through the person matte.
    case gaussianComposite
    /// Apply Core Image's spatially varying blur using the inverse person matte.
    case maskedVariable
}

public struct BackgroundProcessingResult {
    public let image: CGImage
    public let segmentationMilliseconds: Double
    public let compositingMilliseconds: Double
    public let usedNeutralFallback: Bool
    public let failureReason: String?
}

public struct RealtimeBackgroundProcessingResult {
    public let pixelBuffer: CVPixelBuffer
    public let segmentationMilliseconds: Double
    public let compositingMilliseconds: Double
    public let usedNeutralFallback: Bool
    public let failureReason: String?
    public let processingDiagnostics: String?
}

public struct PersonSegmentationMaskDiagnostic {
    public let alignedImage: CIImage
    public let sourceExtent: CGRect
    public let transform: CGAffineTransform
}

public enum BackgroundProcessingFault: Equatable {
    case none
    case visionFailure
    case noMask
    case invalidMaskDimensions
    case compositingFailure
}

/// Normalizes arbitrary Vision mask extents and maps them to the destination
/// frame. Vision may return a reduced-resolution mask (or a non-zero CI extent).
enum SegmentationMaskGeometry {
    static func align(_ mask: CIImage, to destination: CGRect) -> (image: CIImage, transform: CGAffineTransform)? {
        let source = mask.extent
        guard source.width > 0, source.height > 0, destination.width > 0, destination.height > 0 else { return nil }
        let sourceAspect = source.width / source.height
        let destinationAspect = destination.width / destination.height
        // Vision can return a model-grid mask (for example 256×192) whose
        // aspect differs from a 16:9 camera frame. Map the full model extent
        // independently in X and Y; only reject geometry outside safe bounds.
        guard sourceAspect.isFinite, destinationAspect.isFinite,
              sourceAspect >= 0.25, sourceAspect <= 4,
              destinationAspect >= 0.25, destinationAspect <= 4 else { return nil }
        let normalize = CGAffineTransform(translationX: -source.minX, y: -source.minY)
        let scale = CGAffineTransform(scaleX: destination.width / source.width,
                                      y: destination.height / source.height)
        let translate = CGAffineTransform(translationX: destination.minX, y: destination.minY)
        let transform = normalize.concatenating(scale).concatenating(translate)
        return (mask.transformed(by: transform).cropped(to: destination), transform)
    }
}

/// Offline prototype. A source frame is never returned directly: every success
/// composites a person mask over a safe background, and every failure creates
/// a neutral solid frame.
public final class BackgroundReplacementProcessor {
    public static let neutralColor = CIColor(red: 0.24, green: 0.27, blue: 0.30, alpha: 1)
    private static let softBlueBackground = makeSoftBlueBackground(width: 1280, height: 720)

    private let context: CIContext
    private let request: VNGeneratePersonSegmentationRequest
    private let quality: SegmentationQuality
    public let maskPixelFormat: OSType
    public let blurModel: BackgroundBlurModel
    public let maskFeatherRadius: CGFloat
    private var emergencyNeutralBuffers: [String: CVPixelBuffer] = [:]
    // This processor is serialized by the extension's processing queue. Keep
    // just the selected plate so switching presets also bounds memory use.
    private var cachedPhotoKey: String?
    private var cachedPhotoBackground: CIImage?
    private var previousAlignedMask: CIImage?
    private var previousMaskUptimeNanoseconds: UInt64?
    private var timingSamplesMilliseconds: [Double] = []
    private var timingSegmentationMilliseconds: [Double] = []
    private var timingCompositingMilliseconds: [Double] = []
    private var timingReportWritten = false
    private let timingSampleLimit = 300

    /// Offline diagnostic helper for visual mask-alignment audits. Production
    /// frame processing continues to use its existing single Vision request.
    public static func diagnosticPersonMask(for source: CVPixelBuffer, quality: SegmentationQuality) -> PersonSegmentationMaskDiagnostic? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality.visionValue
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(cvPixelBuffer: source, orientation: .up, options: [:]).perform([request])
        } catch { return nil }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        let extent = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        let mask = CIImage(cvPixelBuffer: buffer)
        guard let alignment = SegmentationMaskGeometry.align(mask, to: extent) else { return nil }
        return PersonSegmentationMaskDiagnostic(alignedImage: alignment.image, sourceExtent: mask.extent,
                                                transform: alignment.transform)
    }

    public init(quality: SegmentationQuality,
                maskPixelFormat requestedMaskPixelFormat: OSType = kCVPixelFormatType_OneComponent8,
                blurModel: BackgroundBlurModel = .gaussianComposite,
                maskFeatherRadius: CGFloat = 0.5,
                context: CIContext = CIContext(options: [.cacheIntermediates: true])) {
        self.quality = quality
        self.context = context
        self.blurModel = blurModel
        self.maskFeatherRadius = min(max(maskFeatherRadius, 0), 2)
        self.previousAlignedMask = nil
        self.request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality.visionValue
        let supported: [UInt32]
        if #available(macOS 15.0, *) {
            supported = (try? request.supportedOutputPixelFormats())?.map(\.uint32Value) ?? []
        } else {
            supported = [kCVPixelFormatType_OneComponent8]
        }
        self.maskPixelFormat = supported.contains(requestedMaskPixelFormat)
            ? requestedMaskPixelFormat : kCVPixelFormatType_OneComponent8
        request.outputPixelFormat = self.maskPixelFormat
    }

    public func process(
        _ source: CGImage?,
        treatment: BackgroundTreatment = .solid(BackgroundReplacementProcessor.neutralColor),
        fallbackSize: CGSize = CGSize(width: 1280, height: 720)
    ) -> BackgroundProcessingResult {
        guard let source else {
            return fallback(size: fallbackSize, reason: "missing source frame")
        }

        let segmentationStart = DispatchTime.now().uptimeNanoseconds
        let maskBuffer: CVPixelBuffer
        do {
            let handler = VNImageRequestHandler(cgImage: source, options: [:])
            try handler.perform([request])
            guard let observation = request.results?.first,
                  CVPixelBufferGetWidth(observation.pixelBuffer) > 0,
                  CVPixelBufferGetHeight(observation.pixelBuffer) > 0 else {
                let elapsed = elapsedMilliseconds(since: segmentationStart)
                return fallback(source: source, segmentationMilliseconds: elapsed, reason: "Vision returned no person mask")
            }
            maskBuffer = observation.pixelBuffer
        } catch {
            return fallback(
                source: source,
                segmentationMilliseconds: elapsedMilliseconds(since: segmentationStart),
                reason: "Vision segmentation failed: \(error.localizedDescription)"
            )
        }
        let segmentationMilliseconds = elapsedMilliseconds(since: segmentationStart)

        let compositingStart = DispatchTime.now().uptimeNanoseconds
        let foreground = CIImage(cgImage: source)
        let extent = foreground.extent.integral
        let mask = CIImage(cvPixelBuffer: maskBuffer)
        let scaledMask = mask.transformed(by: CGAffineTransform(
            scaleX: extent.width / mask.extent.width,
            y: extent.height / mask.extent.height
        )).cropped(to: extent)
        let refinedMask = maskFeatherRadius > 0
            ? scaledMask.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: maskFeatherRadius]).cropped(to: extent)
            : scaledMask

        let background: CIImage
        switch treatment {
        case .solid(let color):
            background = CIImage(color: color).cropped(to: extent)
        case .blur(let requestedRadius):
            let radius = min(max(requestedRadius, 0), 48)
            background = blurredBackground(foreground, mask: refinedMask, extent: extent, radius: radius)
        case .softBlue:
            background = Self.softBlueBackground.transformed(by: CGAffineTransform(
                scaleX: extent.width / 1280, y: extent.height / 720)).cropped(to: extent)
        case .photo(let id, let url):
            guard let plate = photoBackground(id: id, url: url, extent: extent) else {
                return fallback(source: source, segmentationMilliseconds: segmentationMilliseconds,
                                compositingMilliseconds: elapsedMilliseconds(since: compositingStart),
                                reason: "selected background image could not be loaded")
            }
            background = plate
        }

        let composite = composite(foreground: foreground, background: background, mask: refinedMask,
                                  treatment: treatment, extent: extent)
        guard let output = context.createCGImage(composite, from: extent) else {
            return fallback(
                source: source,
                segmentationMilliseconds: segmentationMilliseconds,
                compositingMilliseconds: elapsedMilliseconds(since: compositingStart),
                reason: "Core Image could not render the composite"
            )
        }
        return BackgroundProcessingResult(
            image: output,
            segmentationMilliseconds: segmentationMilliseconds,
            compositingMilliseconds: elapsedMilliseconds(since: compositingStart),
            usedNeutralFallback: false,
            failureReason: nil
        )
    }

    /// Camera-buffer entry point. The source remains NV12; Core Image renders
    /// into the caller's format-matched pool, so no per-frame CGImage or BGRA
    /// conversion is introduced. Calls must be serialized per processor because
    /// VNGeneratePersonSegmentationRequest is reused.
    public func process(
        pixelBuffer source: CVPixelBuffer,
        outputPool: CVPixelBufferPool,
        treatment: BackgroundTreatment,
        skinRefinementIntensity: Double = 0,
        lightToneEnabled: Bool = false,
        lightToneIntensity: Double = 0.35,
        fault: BackgroundProcessingFault = .none
    ) -> RealtimeBackgroundProcessingResult {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let sourceFormat = CVPixelBufferGetPixelFormatType(source)
        let poolAttributes = (CVPixelBufferPoolGetPixelBufferAttributes(outputPool) as NSDictionary?) ?? NSDictionary()
        let expectedWidth = (poolAttributes[kCVPixelBufferWidthKey] as? NSNumber)?.intValue ?? 1280
        let expectedHeight = (poolAttributes[kCVPixelBufferHeightKey] as? NSNumber)?.intValue ?? 720
        let expectedFormat = (poolAttributes[kCVPixelBufferPixelFormatTypeKey] as? NSNumber)?.uint32Value
            ?? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let isNV12 = sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let isBGRA = sourceFormat == kCVPixelFormatType_32BGRA
        let validLayout: Bool
        if isNV12 {
            validLayout = width.isMultiple(of: 2) && height.isMultiple(of: 2)
                && CVPixelBufferGetPlaneCount(source) == 2
                && CVPixelBufferGetWidthOfPlane(source, 0) == width
                && CVPixelBufferGetHeightOfPlane(source, 0) == height
                && CVPixelBufferGetWidthOfPlane(source, 1) == width / 2
                && CVPixelBufferGetHeightOfPlane(source, 1) == height / 2
                && CVPixelBufferGetBytesPerRowOfPlane(source, 0) >= width
                && CVPixelBufferGetBytesPerRowOfPlane(source, 1) >= width
        } else if isBGRA {
            validLayout = CVPixelBufferGetPlaneCount(source) == 0
                && CVPixelBufferGetBytesPerRow(source) >= width * 4
        } else { validLayout = false }
        guard width == expectedWidth, height == expectedHeight, sourceFormat == expectedFormat, validLayout else {
            return pixelBufferFallback(pool: outputPool, width: expectedWidth, height: expectedHeight,
                                       format: expectedFormat, reason: "source dimensions/format do not match the advertised output")
        }

        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let segmentationStart = DispatchTime.now().uptimeNanoseconds
        let mask: CIImage
        var maskDiagnostics = "mask=unavailable"
        do {
            guard fault != .visionFailure else { throw ProcessingError.injected("Vision") }
            guard fault != .noMask else { throw ProcessingError.noMask }
            let handler = VNImageRequestHandler(cvPixelBuffer: source, orientation: .up, options: [:])
            try handler.perform([request])
            guard let observation = request.results?.first else { throw ProcessingError.noMask }
            let maskBuffer = observation.pixelBuffer
            let maskWidth = CVPixelBufferGetWidth(maskBuffer)
            let maskHeight = CVPixelBufferGetHeight(maskBuffer)
            let maskFormat = CVPixelBufferGetPixelFormatType(maskBuffer)
            let maskImage = CIImage(cvPixelBuffer: maskBuffer)
            let sourceLayout: String
            if CVPixelBufferGetPlaneCount(source) == 2 {
                sourceLayout = "Y=\(CVPixelBufferGetWidthOfPlane(source,0))x\(CVPixelBufferGetHeightOfPlane(source,0)) stride=\(CVPixelBufferGetBytesPerRowOfPlane(source,0));UV=\(CVPixelBufferGetWidthOfPlane(source,1))x\(CVPixelBufferGetHeightOfPlane(source,1)) stride=\(CVPixelBufferGetBytesPerRowOfPlane(source,1))"
            } else {
                sourceLayout = "planes=\(CVPixelBufferGetPlaneCount(source)) stride=\(CVPixelBufferGetBytesPerRow(source))"
            }
            maskDiagnostics = "source=\(width)x\(height) format=0x\(String(sourceFormat, radix: 16)) layout={\(sourceLayout)} expectedOutput=\(expectedWidth)x\(expectedHeight) mask=\(maskWidth)x\(maskHeight) format=0x\(String(maskFormat, radix: 16)) extent=\(maskImage.extent) quality=\(quality.rawValue) revision=\(request.revision) orientation=up cropRect=full-frame"
            guard fault != .invalidMaskDimensions,
                  maskWidth > 0, maskHeight > 0,
                  maskImage.extent.width > 0, maskImage.extent.height > 0 else {
                throw ProcessingError.invalidMask
            }
            mask = maskImage
        } catch {
            return pixelBufferFallback(pool: outputPool, width: width, height: height, format: sourceFormat,
                                       segmentationMilliseconds: elapsedMilliseconds(since: segmentationStart),
                                       reason: "segmentation failed: \(error.localizedDescription); \(maskDiagnostics)")
        }
        let segmentationMilliseconds = elapsedMilliseconds(since: segmentationStart)
        let compositingStart = DispatchTime.now().uptimeNanoseconds
        let sourceImage = CIImage(cvPixelBuffer: source)
        var foregroundImage = NaturalSkinRetouch.apply(to: sourceImage, intensity: skinRefinementIntensity)
        if lightToneEnabled {
            foregroundImage = NaturalSkinRetouch.applyLightAndTone(to: foregroundImage, intensity: lightToneIntensity)
        }
        // Preserve the matte's soft alpha and remove only subpixel stair steps.
        guard let alignment = SegmentationMaskGeometry.align(mask, to: extent) else {
            return pixelBufferFallback(pool: outputPool, width: width, height: height, format: sourceFormat,
                segmentationMilliseconds: segmentationMilliseconds,
                compositingMilliseconds: elapsedMilliseconds(since: compositingStart),
                reason: "invalid mask aspect ratio or extent; \(maskDiagnostics)")
        }
        var scaledMask = alignment.image
        let nowUptime = DispatchTime.now().uptimeNanoseconds
        let previousMaskIsContinuous = previousMaskUptimeNanoseconds.map {
            nowUptime >= $0 && nowUptime - $0 <= 100_000_000
        } ?? false
        if previousMaskIsContinuous, let previousAlignedMask {
            scaledMask = scaledMask.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.6, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.6, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.6, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ]).applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey:
                previousAlignedMask.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.4, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0.4, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.4, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
                ])]).cropped(to: extent)
        }
        previousAlignedMask = scaledMask
        previousMaskUptimeNanoseconds = nowUptime
        // Contract the matte slightly to suppress background-colored edge halos,
        // then feather the contracted edge by a subpixel amount.
        let contractedMask = scaledMask.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 0.7]).cropped(to: extent)
        let refinedMask = maskFeatherRadius > 0
            ? contractedMask.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: min(maskFeatherRadius, 0.8)]).cropped(to: extent)
            : contractedMask
        let background: CIImage
        switch treatment {
        case .solid(let color):
            background = CIImage(color: color).cropped(to: extent)
        case .blur(let requestedRadius):
            let radius = min(max(requestedRadius, 0), 34)
            background = blurredBackground(sourceImage, mask: refinedMask, extent: extent, radius: radius)
        case .softBlue:
            background = Self.softBlueBackground.transformed(by: CGAffineTransform(
                scaleX: extent.width / 1280, y: extent.height / 720)).cropped(to: extent)
        case .photo(let id, let url):
            guard let plate = photoBackground(id: id, url: url, extent: extent) else {
                return pixelBufferFallback(pool: outputPool, width: width, height: height, format: sourceFormat,
                    segmentationMilliseconds: segmentationMilliseconds,
                    compositingMilliseconds: elapsedMilliseconds(since: compositingStart),
                    reason: "selected background image could not be loaded")
            }
            background = plate
        }
        let composite = composite(foreground: foregroundImage, background: background, mask: refinedMask,
                                  treatment: treatment, extent: extent)
        guard fault != .compositingFailure,
              let destination = allocate(from: outputPool),
              CVPixelBufferGetWidth(destination) == width,
              CVPixelBufferGetHeight(destination) == height,
              CVPixelBufferGetPixelFormatType(destination) == sourceFormat else {
            return pixelBufferFallback(pool: outputPool, width: width, height: height, format: sourceFormat,
                                       segmentationMilliseconds: segmentationMilliseconds,
                                       compositingMilliseconds: elapsedMilliseconds(since: compositingStart),
                                       reason: "compositing/output allocation failed")
        }
        context.render(composite, to: destination, bounds: extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        let compositingMilliseconds = elapsedMilliseconds(since: compositingStart)
        recordTimingSample(segmentationMilliseconds: segmentationMilliseconds,
                           compositingMilliseconds: compositingMilliseconds, width: width, height: height)
        return RealtimeBackgroundProcessingResult(
            pixelBuffer: destination,
            segmentationMilliseconds: segmentationMilliseconds,
            compositingMilliseconds: compositingMilliseconds,
            usedNeutralFallback: false,
            failureReason: nil,
            processingDiagnostics: "\(maskDiagnostics) transform=\(alignment.transform) destination=\(extent)"
        )
    }

    private func recordTimingSample(segmentationMilliseconds: Double, compositingMilliseconds: Double,
                                    width: Int, height: Int) {
        guard width == 1280, height == 720, timingSamplesMilliseconds.count < timingSampleLimit else { return }
        timingSamplesMilliseconds.append(segmentationMilliseconds + compositingMilliseconds)
        timingSegmentationMilliseconds.append(segmentationMilliseconds)
        timingCompositingMilliseconds.append(compositingMilliseconds)
        guard timingSamplesMilliseconds.count == timingSampleLimit, !timingReportWritten else { return }
        timingReportWritten = true
        let sorted = timingSamplesMilliseconds.sorted()
        let average = sorted.reduce(0, +) / Double(sorted.count)
        let p95Index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        let sortedSegmentation = timingSegmentationMilliseconds.sorted()
        let segmentationAverage = sortedSegmentation.reduce(0, +) / Double(sortedSegmentation.count)
        let sortedCompositing = timingCompositingMilliseconds.sorted()
        let compositingAverage = sortedCompositing.reduce(0, +) / Double(sortedCompositing.count)
        segmentationLogger.notice("phase3_720p_timing frames=300 total_average_ms=\(average, privacy: .public) total_p95_ms=\(sorted[p95Index], privacy: .public) total_max_ms=\(sorted.last ?? 0, privacy: .public) segmentation_average_ms=\(segmentationAverage, privacy: .public) segmentation_p95_ms=\(sortedSegmentation[p95Index], privacy: .public) segmentation_max_ms=\(sortedSegmentation.last ?? 0, privacy: .public) compositing_average_ms=\(compositingAverage, privacy: .public) compositing_p95_ms=\(sortedCompositing[p95Index], privacy: .public) compositing_max_ms=\(sortedCompositing.last ?? 0, privacy: .public)")
    }

    private func blurredBackground(_ source: CIImage, mask: CIImage, extent: CGRect, radius: CGFloat) -> CIImage {
        switch blurModel {
        case .gaussianComposite:
            return source.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: extent)
        case .maskedVariable:
            return source.clampedToExtent()
                .applyingFilter("CIMaskedVariableBlur", parameters: [
                    "inputMask": mask,
                    kCIInputRadiusKey: radius
                ])
                .cropped(to: extent)
        }
    }

    private func photoBackground(id: String, url: URL, extent: CGRect) -> CIImage? {
        let key = id + "|" + url.standardizedFileURL.path
        if cachedPhotoKey != key {
            cachedPhotoKey = key
            cachedPhotoBackground = nil
            guard url.isFileURL,
                  let loaded = CIImage(contentsOf: url),
                  loaded.extent.width > 0, loaded.extent.height > 0 else { return nil }
            let target = CGRect(x: 0, y: 0, width: 1280, height: 720)
            let scale = max(target.width / loaded.extent.width, target.height / loaded.extent.height)
            let sized = loaded.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let centered = sized.transformed(by: CGAffineTransform(
                translationX: (target.width - sized.extent.width) / 2 - sized.extent.minX,
                y: (target.height - sized.extent.height) / 2 - sized.extent.minY
            )).cropped(to: target)
            // Very slight defocus softens the plate while preserving its texture.
            cachedPhotoBackground = centered.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.15])
                .cropped(to: target)
        }
        guard let cachedPhotoBackground else { return nil }
        if extent.width == 1280 && extent.height == 720 { return cachedPhotoBackground }
        return cachedPhotoBackground.transformed(by: CGAffineTransform(
            scaleX: extent.width / 1280, y: extent.height / 720
        )).cropped(to: extent)
    }

    private func composite(foreground: CIImage, background: CIImage, mask: CIImage,
                           treatment: BackgroundTreatment, extent: CGRect) -> CIImage {
        if blurModel == .maskedVariable, case .blur = treatment {
            return background.cropped(to: extent)
        }
        return foreground.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask
        ]).cropped(to: extent)
    }

    /// Cached Core Image gradient plate with the four reference colors. A
    /// vertical blend between three smooth linear-gradient bands approximates
    /// the supplied blue falloff without per-frame bitmap generation.
    private static func makeSoftBlueBackground(width: Int, height: Int) -> CIImage {
        // Values sampled from background-only regions of the supplied FaceTime
        // video pane. Core Image coordinates grow upward, so the pale stop is
        // at y=0 and the deep blue stop is at the top edge.
        let stops: [(CGFloat, CIColor)] = [
            (0.00, CIColor(red: 0xD8 / 255.0, green: 0xE8 / 255.0, blue: 0xF8 / 255.0)),
            (0.44, CIColor(red: 0xA6 / 255.0, green: 0xC8 / 255.0, blue: 0xF3 / 255.0)),
            (0.73, CIColor(red: 0x98 / 255.0, green: 0xBE / 255.0, blue: 0xF2 / 255.0)),
            (1.00, CIColor(red: 0x50 / 255.0, green: 0x80 / 255.0, blue: 0xC0 / 255.0))
        ]
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        var image: CIImage?
        for index in 0..<(stops.count - 1) {
            let (startLocation, startColor) = stops[index]
            let (endLocation, endColor) = stops[index + 1]
            let gradient = CIFilter(name: "CILinearGradient")!
            gradient.setValue(CIVector(x: CGFloat(width) / 2,
                                       y: CGFloat(height) * startLocation), forKey: "inputPoint0")
            gradient.setValue(startColor, forKey: "inputColor0")
            gradient.setValue(CIVector(x: CGFloat(width) / 2,
                                       y: CGFloat(height) * endLocation), forKey: "inputPoint1")
            gradient.setValue(endColor, forKey: "inputColor1")
            let band = gradient.outputImage!.cropped(to: extent)
            if let prior = image {
                let blend = CIFilter(name: "CISourceOverCompositing")!
                blend.setValue(band, forKey: kCIInputImageKey)
                blend.setValue(prior, forKey: kCIInputBackgroundImageKey)
                image = blend.outputImage?.cropped(to: extent)
            } else {
                image = band
            }
        }
        return image ?? CIImage(color: stops[0].1).cropped(to: extent)
    }

    private enum ProcessingError: LocalizedError {
        case injected(String), noMask, invalidMask
        var errorDescription: String? {
            switch self {
            case .injected(let stage): "injected \(stage) failure"
            case .noMask: "Vision returned no mask"
            case .invalidMask: "invalid mask dimensions"
            }
        }
    }

    private func pixelBufferFallback(
        pool: CVPixelBufferPool,
        width: Int,
        height: Int,
        format: OSType,
        segmentationMilliseconds: Double = 0,
        compositingMilliseconds: Double = 0,
        reason: String
    ) -> RealtimeBackgroundProcessingResult {
        guard let destination = allocate(from: pool) else {
            // A pool-allocation failure is surfaced as a hard processing failure;
            // the caller must use its independent preallocated neutral buffer.
            return RealtimeBackgroundProcessingResult(
                pixelBuffer: emergencyNeutralBuffer(width: width, height: height, format: format),
                segmentationMilliseconds: segmentationMilliseconds,
                compositingMilliseconds: compositingMilliseconds,
                usedNeutralFallback: true,
                failureReason: "\(reason); neutral pool allocation failed",
                processingDiagnostics: nil
            )
        }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        context.render(CIImage(color: Self.neutralColor).cropped(to: extent), to: destination,
                       bounds: extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        return RealtimeBackgroundProcessingResult(
            pixelBuffer: destination,
            segmentationMilliseconds: segmentationMilliseconds,
            compositingMilliseconds: compositingMilliseconds,
            usedNeutralFallback: true,
            failureReason: reason,
            processingDiagnostics: nil
        )
    }

    private func allocate(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var result: CVPixelBuffer?
        let auxiliaryAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 16] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
                auxiliaryAttributes, &result) == kCVReturnSuccess else { return nil }
        return result
    }

    private func emergencyNeutralBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer {
        let key = "\(width)x\(height)-\(format)"
        if let output = emergencyNeutralBuffers[key] {
            return output
        }
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                      kCVPixelBufferPixelFormatTypeKey: format,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &buffer)
        let output = buffer!
        CVPixelBufferLockBaseAddress(output, [])
        if format == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(output) {
            let stride = CVPixelBufferGetBytesPerRow(output)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = bytes.advanced(by: y * stride)
                for x in 0..<width {
                    let offset = x * 4
                    row[offset] = 0x4D
                    row[offset + 1] = 0x4D
                    row[offset + 2] = 0x4D
                    row[offset + 3] = 0xFF
                }
            }
        } else if CVPixelBufferGetPlaneCount(output) >= 2 {
            let full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let y = full ? UInt8(105) : UInt8(107)
            if let plane = CVPixelBufferGetBaseAddressOfPlane(output, 0) {
                memset(plane, Int32(y), CVPixelBufferGetBytesPerRowOfPlane(output, 0) * height)
            }
            if let plane = CVPixelBufferGetBaseAddressOfPlane(output, 1) {
                memset(plane, 128, CVPixelBufferGetBytesPerRowOfPlane(output, 1) * (height / 2))
            }
        } else if let base = CVPixelBufferGetBaseAddress(output) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(output) * height)
        }
        CVPixelBufferUnlockBaseAddress(output, [])
        emergencyNeutralBuffers[key] = output
        return output
    }

    private func fallback(size: CGSize, reason: String) -> BackgroundProcessingResult {
        let safeSize = CGSize(width: max(1, size.width), height: max(1, size.height))
        let image = renderNeutral(size: safeSize)
        return BackgroundProcessingResult(
            image: image,
            segmentationMilliseconds: 0,
            compositingMilliseconds: 0,
            usedNeutralFallback: true,
            failureReason: reason
        )
    }

    private func fallback(
        source: CGImage,
        segmentationMilliseconds: Double,
        compositingMilliseconds: Double = 0,
        reason: String
    ) -> BackgroundProcessingResult {
        let image = renderNeutral(size: CGSize(width: source.width, height: source.height))
        return BackgroundProcessingResult(
            image: image,
            segmentationMilliseconds: segmentationMilliseconds,
            compositingMilliseconds: compositingMilliseconds,
            usedNeutralFallback: true,
            failureReason: reason
        )
    }

    private func renderNeutral(size: CGSize) -> CGImage {
        let extent = CGRect(origin: .zero, size: size).integral
        let neutral = CIImage(color: Self.neutralColor).cropped(to: extent)
        if let image = context.createCGImage(neutral, from: extent) { return image }
        // CIContext failure is exceptional; CoreGraphics still creates a solid
        // non-source buffer so a failure can never fall back to the input.
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: width * 4, space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(red: 0.24, green: 0.27, blue: 0.30, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return bitmap.makeImage()!
    }

    private func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}

public func loadDownsampledImage(at url: URL, maximumDimension: Int = 1280) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension
          ] as CFDictionary) else {
        throw NSError(domain: "PrivateCamSegmentation", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not decode input image"])
    }
    return image
}
