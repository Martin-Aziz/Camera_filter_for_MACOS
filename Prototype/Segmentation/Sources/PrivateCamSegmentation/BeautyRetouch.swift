import CoreImage
import CoreGraphics
import Foundation
import Vision

/// What the beauty pass should do for one frame. `amount` is the strength
/// slider (0...1); Polished adds under-eye, eye, teeth, lip and cheek work.
public struct BeautySettings: Equatable {
    public var amount: Double
    public var polished: Bool

    public init(amount: Double, polished: Bool) {
        self.amount = min(max(amount, 0), 1)
        self.polished = polished
    }

    public static let off = BeautySettings(amount: 0, polished: false)
    public var isActive: Bool { amount > 0.001 }

    /// Per-effect strengths. Natural is clearly visible at call size;
    /// Polished is stronger and adds the finishing touches.
    struct Levels {
        var smoothing: Double      // skin-mask opacity of the smoothed layer
        var detailCut: Double      // share of full-resolution fine texture removed on skin
        var toneEvening: Double    // pull of local skin color toward the cheek color
        var redness: Double        // extra reduction of red blotches
        var underEye: Double
        var eyes: Double
        var teeth: Double
        var lips: Double
        var cheeks: Double
    }

    var levels: Levels {
        let a = amount
        if polished {
            return Levels(smoothing: min(0.95 * a + 0.05, 0.95), detailCut: 0.5 * a, toneEvening: 0.7 * a,
                          redness: 0.6 * a, underEye: 0.8 * a, eyes: 0.7 * a, teeth: 0.7 * a,
                          lips: 0.6 * a, cheeks: 0.4 * a)
        }
        return Levels(smoothing: min(0.8 * a + 0.05, 0.85), detailCut: 0.35 * a, toneEvening: 0.5 * a,
                      redness: 0.4 * a, underEye: 0, eyes: 0, teeth: 0, lips: 0, cheeks: 0)
    }
}

/// Real-time beauty retouch for the largest face in a frame.
///
/// Work happens on a face crop: masks and the edge-preserving (guided)
/// smoothing run on a copy downscaled to at most `workSide` pixels. The
/// result is applied to the full-resolution crop as a low-frequency
/// correction, while fine texture is only partly reduced, so pores stay
/// faintly visible. Landmarks and the sampled skin color are smoothed over
/// frames so the masks do not jump. Not thread-safe: call from one queue.
final class BeautyRetouchEngine {
    private let context: CIContext
    private let workSide: CGFloat = 224
    private var smoothedRegions: [String: [CGPoint]] = [:]
    private var smoothedBox: CGRect?
    private var skinChroma = SIMD2<Double>(-0.045, 0.075) // gamma-space Cb, Cr of the cheeks
    private var skinChromaInitialized = false
    private var frameCounter = 0

    init(context: CIContext) {
        self.context = context
    }

    func reset() {
        smoothedRegions = [:]
        smoothedBox = nil
        skinChromaInitialized = false
    }

    func apply(to image: CIImage, faces: [VNFaceObservation]?, settings: BeautySettings) -> CIImage {
        guard settings.isActive, let kernels = Kernels.shared,
              let face = faces?.max(by: { $0.boundingBox.width * $0.boundingBox.height
                                          < $1.boundingBox.width * $1.boundingBox.height }),
              let landmarks = face.landmarks else {
            reset()
            return image
        }
        let extent = image.extent
        let geometry = stabilizedGeometry(face: face, landmarks: landmarks, imageSize: extent.size)
        let box = geometry.box
        // Crop: face plus ears at the sides, forehead above and the neck below.
        let region = CGRect(x: box.minX - box.width * 0.28, y: box.minY - box.height * 0.6,
                            width: box.width * 1.56, height: box.height * 1.78)
            .integral.intersection(extent)
        guard region.width >= 32, region.height >= 32 else { return image }
        let scale = min(1, workSide / max(region.width, region.height))
        let workSize = CGSize(width: (region.width * scale).rounded(.down), height: (region.height * scale).rounded(.down))
        let toWork = CGAffineTransform(translationX: -region.minX, y: -region.minY).concatenating(.init(scaleX: scale, y: scale))
        let fromWork = toWork.inverted()
        let workExtent = CGRect(origin: .zero, size: workSize)
        func workPoints(_ name: String) -> [CGPoint] { (geometry.regions[name] ?? []).map { $0.applying(toWork) } }

        let levels = settings.levels
        let full = image.cropped(to: region)
        let work = full.transformed(by: toWork).cropped(to: workExtent)

        // Skin color target, refreshed every 10 frames from both cheeks.
        frameCounter &+= 1
        if !skinChromaInitialized || frameCounter % 10 == 0 {
            sampleSkinChroma(work, cheeks: cheekRects(geometry: geometry, toWork: toWork, workSize: workSize))
        }

        // Masks in work space.
        let masks = MaskPainter(size: workSize)
        let faceBox = box.applying(toWork)
        let skinShape = masks.skinShape(contour: workPoints("faceContour"), faceBox: faceBox,
            exclusions: [(workPoints("leftEye"), 1.7), (workPoints("rightEye"), 1.7),
                         (workPoints("leftEyebrow"), 1.35), (workPoints("rightEyebrow"), 1.35),
                         (workPoints("outerLips"), 1.12)],
            nose: workPoints("nose"))
        let skinLikelihood = kernels.skin.apply(extent: workExtent, arguments: [
            work, CIVector(x: skinChroma.x, y: skinChroma.y), 0.06])!
            // Nothing is changed near the crop border, so no seam can appear there.
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: edgeFade(workExtent)])
            .cropped(to: workExtent)
        let skinMask = feathered(skinShape, radius: 2.5, extent: workExtent)
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: skinLikelihood])
            .cropped(to: workExtent)

        // Edge-preserving smoothing: self-guided filter on the work crop.
        let radius = max(2.0, Double(workSize.width) * 0.022)
        let epsilon = 0.0009 + 0.0035 * settings.amount
        let mean = boxBlur(work, radius: radius, extent: workExtent)
        let meanSquare = boxBlur(kernels.square.apply(extent: workExtent, arguments: [work])!, radius: radius, extent: workExtent)
        let a = kernels.guidedA.apply(extent: workExtent, arguments: [mean, meanSquare, epsilon])!
        let b = kernels.guidedB.apply(extent: workExtent, arguments: [mean, a])!
        let smooth = kernels.guidedOutput.apply(extent: workExtent, arguments: [
            work, boxBlur(a, radius: radius, extent: workExtent), boxBlur(b, radius: radius, extent: workExtent)])!

        // Even skin tone: shift local low-frequency chroma toward the cheek color.
        let low = smooth.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Double(workSize.width) * 0.06])
            .cropped(to: workExtent)
        let toned = kernels.tone.apply(extent: workExtent, arguments: [
            smooth, low, CIVector(x: skinChroma.x, y: skinChroma.y), levels.toneEvening, levels.redness])!
        var retouchedWork = blend(toned, over: work, mask: skinMask, strength: levels.smoothing, extent: workExtent)

        if levels.underEye > 0 {
            let underEye = masks.underEye(leftEye: workPoints("leftEye"), rightEye: workPoints("rightEye"))
            let underEyeMask = feathered(underEye, radius: 3, extent: workExtent)
                .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: skinLikelihood])
                .cropped(to: workExtent)
            let lifted = kernels.lift.apply(extent: workExtent, arguments: [retouchedWork, levels.underEye])!
            retouchedWork = blend(lifted, over: retouchedWork, mask: underEyeMask, strength: 1, extent: workExtent)
        }

        // Back to full resolution: add the low-frequency change, and remove part
        // of the fine texture on skin only (frequency separation).
        // The work-space result (signed correction + skin mask) is rendered into
        // small owned half-float buffers. This splits one very large graph in two:
        // as a single graph Core Image produced tile-shaped artifacts.
        let workDelta = kernels.difference.apply(extent: workExtent, arguments: [retouchedWork, work])!
        guard let deltaImage = materialize(workDelta, extent: workExtent, slot: 0),
              let skinImage = materialize(skinMask, extent: workExtent, slot: 1) else { return image }
        let delta = deltaImage.transformed(by: fromWork).cropped(to: region)
        let fullSkinMask = skinImage.transformed(by: fromWork).cropped(to: region)
        let fullBlur = full.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.4])
            .cropped(to: region)
        var result = kernels.recombine.apply(extent: region, arguments: [
            full, delta, fullBlur, fullSkinMask, levels.detailCut])!

        if levels.eyes > 0 {
            let eyes = masks.polygons([workPoints("leftEye"), workPoints("rightEye")], grow: 1.05)
            let eyeMask = feathered(eyes, radius: 0.8, extent: workExtent).transformed(by: fromWork).cropped(to: region)
            let sharpened = result.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.55 * levels.eyes, kCIInputRadiusKey: 1.4])
            let brightened = kernels.lift.apply(extent: region, arguments: [sharpened, 0.45 * levels.eyes])!
            result = blend(brightened, over: result, mask: eyeMask, strength: 1, extent: region)
        }
        if levels.teeth > 0 {
            let mouth = masks.polygons([workPoints("innerLips")], grow: 1.0)
            let mouthMask = feathered(mouth, radius: 0.8, extent: workExtent).transformed(by: fromWork).cropped(to: region)
            let whitened = kernels.teeth.apply(extent: region, arguments: [result, levels.teeth])!
            result = blend(whitened, over: result, mask: mouthMask, strength: 1, extent: region)
        }
        if levels.lips > 0 {
            let lips = masks.ring(outer: workPoints("outerLips"), inner: workPoints("innerLips"))
            let lipMask = feathered(lips, radius: 1.5, extent: workExtent).transformed(by: fromWork).cropped(to: region)
            let tinted = kernels.lipTint.apply(extent: region, arguments: [result, levels.lips])!
            result = blend(tinted, over: result, mask: lipMask, strength: 1, extent: region)
        }
        if levels.cheeks > 0 {
            let cheeks = masks.ellipses(cheekRects(geometry: geometry, toWork: toWork, workSize: workSize, grow: 2.4))
            let cheekMask = feathered(cheeks, radius: 7, extent: workExtent)
                .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: skinLikelihood])
                .cropped(to: workExtent).transformed(by: fromWork).cropped(to: region)
            let warmed = kernels.warm.apply(extent: region, arguments: [result, levels.cheeks])!
            result = blend(warmed, over: result, mask: cheekMask, strength: 1, extent: region)
        }
        return result.cropped(to: region).composited(over: image).cropped(to: extent)
    }

    // MARK: Geometry

    private struct Geometry {
        var box: CGRect
        var regions: [String: [CGPoint]]
    }

    /// Landmarks in image pixels, smoothed over frames. A large jump (new
    /// face or a fast move) resets the history instead of lagging behind.
    private func stabilizedGeometry(face: VNFaceObservation, landmarks: VNFaceLandmarks2D, imageSize: CGSize) -> Geometry {
        let box = VNImageRectForNormalizedRect(face.boundingBox, Int(imageSize.width), Int(imageSize.height))
        var current: [String: [CGPoint]] = [:]
        let named: [(String, VNFaceLandmarkRegion2D?)] = [
            ("faceContour", landmarks.faceContour), ("leftEye", landmarks.leftEye), ("rightEye", landmarks.rightEye),
            ("leftEyebrow", landmarks.leftEyebrow), ("rightEyebrow", landmarks.rightEyebrow),
            ("outerLips", landmarks.outerLips), ("innerLips", landmarks.innerLips), ("nose", landmarks.nose)]
        for (name, region) in named {
            if let region, region.pointCount > 0 { current[name] = region.pointsInImage(imageSize: imageSize) }
        }
        let moved = smoothedBox.map { previous in
            hypot(previous.midX - box.midX, previous.midY - box.midY) > box.width * 0.12
                || abs(previous.width - box.width) > box.width * 0.15
        } ?? true
        guard !moved else {
            smoothedRegions = current
            smoothedBox = box
            return Geometry(box: box, regions: current)
        }
        let alpha: CGFloat = 0.45
        var blended: [String: [CGPoint]] = [:]
        for (name, points) in current {
            if let previous = smoothedRegions[name], previous.count == points.count {
                blended[name] = zip(previous, points).map { old, new in
                    CGPoint(x: old.x + (new.x - old.x) * alpha, y: old.y + (new.y - old.y) * alpha)
                }
            } else {
                blended[name] = points
            }
        }
        let previousBox = smoothedBox ?? box
        let blendedBox = CGRect(x: previousBox.minX + (box.minX - previousBox.minX) * alpha,
                                y: previousBox.minY + (box.minY - previousBox.minY) * alpha,
                                width: previousBox.width + (box.width - previousBox.width) * alpha,
                                height: previousBox.height + (box.height - previousBox.height) * alpha)
        smoothedRegions = blended
        smoothedBox = blendedBox
        return Geometry(box: blendedBox, regions: blended)
    }

    /// Cheek patches between each eye and the mouth corner, in work space.
    private func cheekRects(geometry: Geometry, toWork: CGAffineTransform, workSize: CGSize, grow: CGFloat = 1) -> [CGRect] {
        guard let left = geometry.regions["leftEye"], let right = geometry.regions["rightEye"],
              let lips = geometry.regions["outerLips"], !left.isEmpty, !right.isEmpty, !lips.isEmpty else { return [] }
        let lipMinX = lips.map(\.x).min()!, lipMaxX = lips.map(\.x).max()!
        let lipMidY = lips.map(\.y).reduce(0, +) / CGFloat(lips.count)
        let side = geometry.box.width * 0.09 * grow
        return [(left, lipMinX), (right, lipMaxX)].map { eye, cornerX in
            let eyeCenter = CGPoint(x: eye.map(\.x).reduce(0, +) / CGFloat(eye.count),
                                    y: eye.map(\.y).reduce(0, +) / CGFloat(eye.count))
            let center = CGPoint(x: (eyeCenter.x + cornerX) / 2, y: (eyeCenter.y + lipMidY) / 2 + geometry.box.height * 0.04)
            return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side).applying(toWork)
        }.filter { CGRect(origin: .zero, size: workSize).contains(CGPoint(x: $0.midX, y: $0.midY)) }
    }

    private func sampleSkinChroma(_ work: CIImage, cheeks: [CGRect]) {
        var samples: [SIMD2<Double>] = []
        for rect in cheeks {
            let average = work.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
            var pixel = [Float](repeating: 0, count: 4)
            context.render(average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: nil)
            let g = pixel.prefix(3).map { Double(max($0, 0)).squareRoot() }
            let y = 0.299 * g[0] + 0.587 * g[1] + 0.114 * g[2]
            guard y > 0.12 else { continue }
            samples.append(SIMD2((g[2] - y) * 0.564, (g[0] - y) * 0.713))
        }
        guard !samples.isEmpty else { return }
        let mean = samples.reduce(SIMD2<Double>(0, 0), +) / Double(samples.count)
        // Only plausible skin chroma is accepted; the color then drifts slowly.
        guard mean.y > 0.0, mean.y < 0.25, mean.x > -0.2, mean.x < 0.05 else { return }
        skinChroma = skinChromaInitialized ? skinChroma + (mean - skinChroma) * 0.25 : mean
        skinChromaInitialized = true
    }

    // MARK: Helpers

    /// Two reusable buffer pairs: the frame being built and the one possibly
    /// still referenced by the previous render.
    private var buffers: [[CVPixelBuffer]] = [[], []]
    private var bufferGeneration = 0

    private func materialize(_ image: CIImage, extent: CGRect, slot: Int) -> CIImage? {
        if slot == 0 { bufferGeneration ^= 1 }
        let width = Int(extent.width), height = Int(extent.height)
        var pair = buffers[bufferGeneration]
        if pair.count != 2 || CVPixelBufferGetWidth(pair[0]) != width || CVPixelBufferGetHeight(pair[0]) != height {
            pair = []
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                              kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
            for _ in 0..<2 {
                var buffer: CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_64RGBAHalf,
                                          attributes, &buffer) == kCVReturnSuccess, let buffer else { return nil }
                pair.append(buffer)
            }
            buffers[bufferGeneration] = pair
        }
        context.render(image, to: pair[slot], bounds: extent, colorSpace: nil)
        return CIImage(cvPixelBuffer: pair[slot], options: [.colorSpace: NSNull()])
    }

    /// 1 inside, fading to 0 over the outer 10% of the crop.
    private func edgeFade(_ extent: CGRect) -> CIImage {
        let inset = extent.insetBy(dx: extent.width * 0.1, dy: extent.height * 0.1)
        return CIImage(color: .white).cropped(to: inset)
            .composited(over: CIImage(color: .black).cropped(to: extent))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: extent.width * 0.04])
            .cropped(to: extent)
    }

    private func boxBlur(_ image: CIImage, radius: Double, extent: CGRect) -> CIImage {
        image.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
    }

    private func feathered(_ mask: CIImage, radius: Double, extent: CGRect) -> CIImage {
        mask.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
    }

    private func blend(_ top: CIImage, over bottom: CIImage, mask: CIImage, strength: Double, extent: CGRect) -> CIImage {
        // Always normalize the mask through a color matrix: passing a composited
        // mask straight to CIBlendWithMask applied the top layer to the whole crop.
        let scaledMask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: strength, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: strength, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        return top.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: bottom, kCIInputMaskImageKey: scaledMask]).cropped(to: extent)
    }
}

/// Grayscale masks drawn on the CPU at work-crop size (a few hundred pixels).
private struct MaskPainter {
    let size: CGSize

    private func draw(_ body: (CGContext) -> Void) -> CIImage {
        let width = max(Int(size.width), 1), height = max(Int(size.height), 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        body(context)
        guard let image = context.makeImage() else { return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)) }
        return CIImage(cgImage: image)
    }

    private static func path(_ points: [CGPoint], grow: CGFloat) -> CGPath? {
        guard points.count > 2 else { return nil }
        let center = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                             y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        let path = CGMutablePath()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: center.x + (point.x - center.x) * grow, y: center.y + (point.y - center.y) * grow)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    /// Face skin: the jaw contour joined with the face ellipse (forehead and
    /// ears), plus a neck band that fades out downward; minus eyes, brows,
    /// lips and nostrils.
    func skinShape(contour: [CGPoint], faceBox: CGRect, exclusions: [([CGPoint], CGFloat)], nose: [CGPoint]) -> CIImage {
        draw { context in
            context.setFillColor(gray: 1, alpha: 1)
            if let path = Self.path(contour, grow: 1.0) { context.addPath(path); context.fillPath() }
            context.fillEllipse(in: CGRect(x: faceBox.minX - faceBox.width * 0.06, y: faceBox.minY + faceBox.height * 0.05,
                                           width: faceBox.width * 1.12, height: faceBox.height * 1.08))
            let chinY = contour.map(\.y).min() ?? faceBox.minY
            let neck = CGRect(x: faceBox.midX - faceBox.width * 0.32, y: max(chinY - faceBox.height * 0.6, 0),
                              width: faceBox.width * 0.64, height: chinY - max(chinY - faceBox.height * 0.6, 0) + faceBox.height * 0.1)
            if neck.height > 1, let gradient = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(),
                                                          colorComponents: [0, 1, 1, 1], locations: [0, 0.6], count: 2) {
                context.saveGState()
                context.clip(to: neck)
                context.drawLinearGradient(gradient, start: CGPoint(x: neck.midX, y: neck.minY),
                                           end: CGPoint(x: neck.midX, y: neck.maxY), options: [])
                context.restoreGState()
            }
            context.setFillColor(gray: 0, alpha: 1)
            for (points, grow) in exclusions {
                if let path = Self.path(points, grow: grow) { context.addPath(path); context.fillPath() }
            }
            if nose.count > 2 {
                // Nostrils: the lower part of the nose outline.
                let minX = nose.map(\.x).min()!, maxX = nose.map(\.x).max()!
                let minY = nose.map(\.y).min()!, maxY = nose.map(\.y).max()!
                let height = maxY - minY, width = maxX - minX
                context.fillEllipse(in: CGRect(x: minX + width * 0.05, y: minY - height * 0.12,
                                               width: width * 0.9, height: height * 0.42))
            }
        }
    }

    func underEye(leftEye: [CGPoint], rightEye: [CGPoint]) -> CIImage {
        draw { context in
            context.setFillColor(gray: 1, alpha: 1)
            for eye in [leftEye, rightEye] where eye.count > 2 {
                let minX = eye.map(\.x).min()!, maxX = eye.map(\.x).max()!
                let minY = eye.map(\.y).min()!, maxY = eye.map(\.y).max()!
                let width = maxX - minX, height = max(maxY - minY, width * 0.3)
                context.fillEllipse(in: CGRect(x: minX - width * 0.05, y: minY - height * 1.45,
                                               width: width * 1.1, height: height * 1.2))
            }
        }
    }

    func polygons(_ regions: [[CGPoint]], grow: CGFloat) -> CIImage {
        draw { context in
            context.setFillColor(gray: 1, alpha: 1)
            for region in regions { if let path = Self.path(region, grow: grow) { context.addPath(path); context.fillPath() } }
        }
    }

    func ring(outer: [CGPoint], inner: [CGPoint]) -> CIImage {
        draw { context in
            context.setFillColor(gray: 1, alpha: 1)
            if let path = Self.path(outer, grow: 1) { context.addPath(path); context.fillPath() }
            context.setFillColor(gray: 0, alpha: 1)
            if let path = Self.path(inner, grow: 1.05) { context.addPath(path); context.fillPath() }
        }
    }

    func ellipses(_ rects: [CGRect]) -> CIImage {
        draw { context in
            context.setFillColor(gray: 1, alpha: 1)
            for rect in rects { context.fillEllipse(in: rect) }
        }
    }
}

/// Core Image kernels. Inputs are in linear light; color logic converts to
/// an approximate gamma space (square root) and back.
private struct Kernels {
    let square: CIColorKernel
    let guidedA: CIColorKernel
    let guidedB: CIColorKernel
    let guidedOutput: CIColorKernel
    let tone: CIColorKernel
    let skin: CIColorKernel
    let lift: CIColorKernel
    let teeth: CIColorKernel
    let lipTint: CIColorKernel
    let warm: CIColorKernel
    let difference: CIColorKernel
    let recombine: CIColorKernel

    static let shared: Kernels? = Kernels()

    private init?() {
        let toYCC = """
        vec3 g = sqrt(max(s.rgb, vec3(0.0)));
        float y = dot(g, vec3(0.299, 0.587, 0.114));
        float cb = (g.b - y) * 0.564;
        float cr = (g.r - y) * 0.713;
        """
        let fromYCC = """
        vec3 o = vec3(y + 1.403 * cr, y - 0.344 * cb - 0.714 * cr, y + 1.773 * cb);
        o = clamp(o, 0.0, 1.0);
        return vec4(o * o, s.a);
        """
        func make(_ source: String) -> CIColorKernel? { CIColorKernel(source: source) }
        guard let square = make("kernel vec4 k(__sample s) { return vec4(s.rgb * s.rgb, 1.0); }"),
              let guidedA = make("""
                kernel vec4 k(__sample m, __sample m2, float eps) {
                    vec3 v = max(m2.rgb - m.rgb * m.rgb, vec3(0.0));
                    return vec4(v / (v + eps), 1.0);
                }
                """),
              let guidedB = make("kernel vec4 k(__sample m, __sample a) { return vec4(m.rgb - a.rgb * m.rgb, 1.0); }"),
              let guidedOutput = make("kernel vec4 k(__sample i, __sample ma, __sample mb) { return vec4(ma.rgb * i.rgb + mb.rgb, i.a); }"),
              let tone = make("""
                kernel vec4 k(__sample s, __sample l, vec2 target, float t, float red) {
                    \(toYCC)
                    vec3 gl = sqrt(max(l.rgb, vec3(0.0)));
                    float yl = dot(gl, vec3(0.299, 0.587, 0.114));
                    float cbl = (gl.b - yl) * 0.564;
                    float crl = (gl.r - yl) * 0.713;
                    cb += t * (target.x - cbl);
                    cr += t * (target.y - crl) - red * max(crl - target.y, 0.0);
                    \(fromYCC)
                }
                """),
              let skin = make("""
                kernel vec4 k(__sample s, vec2 target, float tol) {
                    \(toYCC)
                    float d = distance(vec2(cb, cr), target);
                    float w = (1.0 - smoothstep(tol * 0.55, tol, d)) * smoothstep(0.08, 0.2, y);
                    return vec4(w, w, w, 1.0);
                }
                """),
              let lift = make("""
                kernel vec4 k(__sample s, float t) {
                    \(toYCC)
                    y += t * 0.11 * (1.0 - y);
                    \(fromYCC)
                }
                """),
              let teeth = make("""
                kernel vec4 k(__sample s, float t) {
                    \(toYCC)
                    float bright = smoothstep(0.42, 0.62, y);
                    cb *= 1.0 - 0.5 * t * bright;
                    cr *= 1.0 - 0.4 * t * bright;
                    y += 0.05 * t * bright;
                    \(fromYCC)
                }
                """),
              let lipTint = make("""
                kernel vec4 k(__sample s, float t) {
                    \(toYCC)
                    cb *= 1.0 + 0.12 * t;
                    cr *= 1.0 + 0.22 * t;
                    cr += 0.008 * t;
                    \(fromYCC)
                }
                """),
              let warm = make("""
                kernel vec4 k(__sample s, float t) {
                    \(toYCC)
                    cr += 0.018 * t;
                    cb -= 0.006 * t;
                    \(fromYCC)
                }
                """),
              let difference = make("kernel vec4 k(__sample a, __sample b) { return vec4(a.rgb - b.rgb, 1.0); }"),
              let recombine = make("""
                kernel vec4 k(__sample o, __sample d, __sample b, __sample m, float cut) {
                    vec3 detail = o.rgb - b.rgb;
                    return vec4(max(o.rgb + d.rgb - cut * m.r * detail, vec3(0.0)), o.a);
                }
                """)
        else { return nil }
        self.square = square; self.guidedA = guidedA; self.guidedB = guidedB; self.guidedOutput = guidedOutput
        self.tone = tone; self.skin = skin; self.lift = lift; self.teeth = teeth; self.lipTint = lipTint
        self.warm = warm; self.difference = difference; self.recombine = recombine
    }
}
