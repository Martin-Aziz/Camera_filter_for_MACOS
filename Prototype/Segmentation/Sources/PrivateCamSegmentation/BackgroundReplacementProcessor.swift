import CoreImage
import CoreVideo
import ImageIO
import Vision
import Foundation
public enum NaturalSkinRetouch {
    /// Returns the foreground with low-strength skin-only smoothing. Eye, brow,
    /// lip and contour landmark regions are excluded from the mask.
    public static func apply(to image: CIImage, intensity: Double) -> CIImage {
        let strength = min(max(intensity, 0), 0.4)
        guard strength > 0, image.extent.width > 0, image.extent.height > 0 else { return image }
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        let analysisScale = min(1, 320 / max(image.extent.width, image.extent.height))
        let analysisImage = analysisScale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: analysisScale, y: analysisScale))
            : image
        do {
            try VNImageRequestHandler(ciImage: analysisImage, options: [:]).perform([request])
        } catch { return image }
        guard let faces = request.results, !faces.isEmpty else { return image }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return image }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for face in faces {
            let box = face.boundingBox
            let rect = CGRect(x: box.minX * extent.width, y: box.minY * extent.height,
                              width: box.width * extent.width, height: box.height * extent.height)
            context.setFillColor(gray: CGFloat(strength), alpha: 1)
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
        guard let maskCG = context.makeImage() else { return image }
        let mask = CIImage(cgImage: maskCG).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        let radius = 0.8 + strength * 2.5
        let softened = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
        return softened.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask
        ]).cropped(to: extent)
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
}

public enum BackgroundProcessingFault: Equatable {
    case none
    case visionFailure
    case invalidMaskDimensions
    case compositingFailure
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

    public init(quality: SegmentationQuality,
                maskPixelFormat requestedMaskPixelFormat: OSType = kCVPixelFormatType_OneComponent8,
                blurModel: BackgroundBlurModel = .gaussianComposite,
                maskFeatherRadius: CGFloat = 0.5,
                context: CIContext = CIContext(options: [.cacheIntermediates: true])) {
        self.quality = quality
        self.context = context
        self.blurModel = blurModel
        self.maskFeatherRadius = min(max(maskFeatherRadius, 0), 2)
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
        guard width == expectedWidth, height == expectedHeight,
              width.isMultiple(of: 2), height.isMultiple(of: 2),
              sourceFormat == expectedFormat,
              sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            return pixelBufferFallback(pool: outputPool, width: expectedWidth, height: expectedHeight,
                                       format: expectedFormat, reason: "source dimensions/format do not match the advertised output")
        }

        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let segmentationStart = DispatchTime.now().uptimeNanoseconds
        let mask: CIImage
        do {
            guard fault != .visionFailure else { throw ProcessingError.injected("Vision") }
            let handler = VNImageRequestHandler(cvPixelBuffer: source, orientation: .up, options: [:])
            try handler.perform([request])
            guard let observation = request.results?.first else { throw ProcessingError.noMask }
            let maskBuffer = observation.pixelBuffer
            let maskWidth = CVPixelBufferGetWidth(maskBuffer)
            let maskHeight = CVPixelBufferGetHeight(maskBuffer)
            guard fault != .invalidMaskDimensions,
                  maskWidth > 0, maskHeight > 0,
                  maskWidth <= width, maskHeight <= height else {
                throw ProcessingError.invalidMask
            }
            mask = CIImage(cvPixelBuffer: maskBuffer)
        } catch {
            return pixelBufferFallback(pool: outputPool, width: width, height: height, format: sourceFormat,
                                       segmentationMilliseconds: elapsedMilliseconds(since: segmentationStart),
                                       reason: "segmentation failed: \(error.localizedDescription)")
        }
        let segmentationMilliseconds = elapsedMilliseconds(since: segmentationStart)
        let compositingStart = DispatchTime.now().uptimeNanoseconds
        let sourceImage = CIImage(cvPixelBuffer: source)
        let foregroundImage = NaturalSkinRetouch.apply(to: sourceImage, intensity: skinRefinementIntensity)
        // Preserve the matte's soft alpha and remove only subpixel stair steps.
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
        return RealtimeBackgroundProcessingResult(
            pixelBuffer: destination,
            segmentationMilliseconds: segmentationMilliseconds,
            compositingMilliseconds: elapsedMilliseconds(since: compositingStart),
            usedNeutralFallback: false,
            failureReason: nil
        )
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
                failureReason: "\(reason); neutral pool allocation failed"
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
            failureReason: reason
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
