import AppKit
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import PrivateCamSegmentation

@main enum SkinQualityAudit {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("usage: skin-quality-audit fixture-directory output-directory") }
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let names = ["SkinTest-medium-brown", "SkinTest-light-textured", "SkinTest-deep-lowkey", "SkinTest-light-medium"]
        let strengths: [(String, Double)] = [("off",0), ("subtle",0.16), ("refined",0.30), ("custom-010",0.10), ("custom-020",0.20), ("custom-040",0.40)]
        let context = CIContext(options: [.cacheIntermediates: false])
        var report = "fixture,width,height,faces,intensity,mask_face_coverage_pct,mask_face_mean_alpha,mask_outside_coverage_pct,effect_mask_face_coverage_pct,effect_mask_mean_alpha,skin_mask_mae_rgb,face_mae_rgb,nonface_mae_rgb,face_mean_delta_rgb,nonface_mean_delta_rgb,integrated_fallback,integrated_p50_ms,integrated_p95_ms,integrated_max_ms,samples\n"
        var sampleReport = "fixture,intensity,iteration,total_ms\n"
        for name in names {
            let url = fixtures.appendingPathComponent(name + ".png")
            let cg = try loadDownsampledImage(at: url, maximumDimension: 900)
            let source = CIImage(cgImage: cg)
            let faceRequest = VNDetectFaceLandmarksRequest()
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([faceRequest])
            let faces = faceRequest.results ?? []
            guard !faces.isEmpty else { throw NSError(domain:"SkinQualityAudit", code:1, userInfo:[NSLocalizedDescriptionKey:"No detectable face in \(name)"]) }
            let original = try render(source, context: context)
            try save(original, name + "-original.png", output)
            let baselineFace = try rgbPixels(original)
            let faceRects = faces.map { CGRect(x: $0.boundingBox.minX * CGFloat(cg.width), y: $0.boundingBox.minY * CGFloat(cg.height), width: $0.boundingBox.width * CGFloat(cg.width), height: $0.boundingBox.height * CGFloat(cg.height)) }
            var comparisons: [String: CGImage] = [:]
            let diagnosticMask = NaturalSkinRetouch.diagnosticMask(for: source, intensity: 0.4)
            guard let diagnosticMask else { throw NSError(domain: "SkinQualityAudit", code: 10) }
            let maskCG = try render(diagnosticMask, context: context)
            let maskStats = try maskCoverage(maskCG, faceRects: faceRects)
            try save(maskCG, name + "-skin-mask.png", output)
            let tint = CIImage(color: CIColor(red: 0.05, green: 0.9, blue: 1.0, alpha: 0.55)).cropped(to: source.extent)
            let overlay = tint.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: source,
                kCIInputMaskImageKey: diagnosticMask
            ]).cropped(to: source.extent)
            try save(try render(overlay, context: context), name + "-skin-mask-overlay.png", output)
            let pool = try makePool(width: 640, height: 480)
            let frame = cameraFrame(source, width: 640, height: 480)
            let pixelBuffer = try makeBuffer(frame, pool: pool, context: context)
            for (label, strength) in strengths {
                let direct = NaturalSkinRetouch.apply(to: source, intensity: strength)
                let rendered = try render(direct, context: context)
                try save(rendered, name + "-" + label + ".png", output)
                comparisons[label] = rendered
                let metrics = try pixelDiff(baselineFace, rgbPixels(rendered), width: cg.width, height: cg.height, faceRects: faceRects)
                let skinMAE = try maskedMeanAbsoluteDifference(baselineFace, rgbPixels(rendered), mask: maskCG)
                var effectCoverage=0.0,effectAlpha=0.0
                if let effectMask=NaturalSkinRetouch.diagnosticMask(for:source,intensity:strength),
                   let effectMaskCG=try? render(effectMask,context:context),
                   let effectStats=try? maskCoverage(effectMaskCG,faceRects:faceRects) {
                    effectCoverage=effectStats.faceCoveragePct; effectAlpha=effectStats.faceMeanAlpha
                }
                let processor = BackgroundReplacementProcessor(quality: .fast, maskFeatherRadius: 1.1)
                var times: [Double] = []; var integrated: CVPixelBuffer?; var fallback = false
                for index in 0..<9 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let result = processor.process(pixelBuffer: pixelBuffer, outputPool: pool, treatment: .blur(radius: 16), skinRefinementIntensity: strength)
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    if index >= 1 { times.append(elapsed); sampleReport += "\(name),\(label),\(index),\(fmt(elapsed))\n" }
                    integrated = result.pixelBuffer; fallback = fallback || result.usedNeutralFallback
                }
                if let integrated, let integratedCG = context.createCGImage(CIImage(cvPixelBuffer: integrated), from: CGRect(x:0,y:0,width:640,height:480)) {
                    try save(integratedCG, name + "-pipeline-" + label + ".png", output)
                }
                let sorted = times.sorted()
                report += "\(name),\(cg.width),\(cg.height),\(faces.count),\(label),\(fmt(maskStats.faceCoveragePct)),\(fmt(maskStats.faceMeanAlpha)),\(fmt(maskStats.outsideCoveragePct)),\(fmt(effectCoverage)),\(fmt(effectAlpha)),\(fmt(skinMAE)),\(fmt(metrics.face)),\(fmt(metrics.nonface)),\(fmt(metrics.faceSigned)),\(fmt(metrics.nonfaceSigned)),\(fallback),\(fmt(percentile(sorted,0.50))),\(fmt(percentile(sorted,0.95))),\(fmt(sorted.last ?? 0)),\(sorted.count)\n"
            }
            print("fixture=\(name) dimensions=\(cg.width)x\(cg.height) detected_faces=\(faces.count) bbox=\(faces.map{$0.boundingBox})")
            let order = strengths.map(\.0)
            try saveSheet([original] + order.compactMap { comparisons[$0] }, name + "-comparison.png", output, columns: 3)
            let labels = ["Original"] + order.map { $0 == "off" ? "Off" : $0 == "subtle" ? "Subtle" : $0 == "refined" ? "Refined" : "Custom \($0.replacingOccurrences(of: "custom-", with: ""))" }
            let nativeTiles = [original] + order.compactMap { comparisons[$0] }
            try saveLabeledSheet(Array(zip(labels, nativeTiles)), name + "-native-review.png", output, columns: 2)
            let cameraTiles = try ([source] + order.map { key -> CIImage in
                CIImage(cgImage: comparisons[key]!).cropped(to: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }).map { try render(cameraFrame($0, width: 1280, height: 720), context: context) }
            try saveLabeledSheet(Array(zip(labels, cameraTiles)), name + "-720p-review.png", output, columns: 2)
            let participantTiles = try cameraTiles.map { try render(resize(CIImage(cgImage: $0), width: 320, height: 180), context: context) }
            try saveLabeledSheet(Array(zip(labels, participantTiles)), name + "-participant-review.png", output, columns: 2)
            let primaryFace = faceRects[0]
            let crop = CGRect(x: max(0, primaryFace.minX - primaryFace.width * 0.18),
                              y: max(0, CGFloat(cg.height) - primaryFace.maxY - primaryFace.height * 0.18),
                              width: min(CGFloat(cg.width), primaryFace.width * 1.36),
                              height: min(CGFloat(cg.height), primaryFace.height * 1.36))
            let cropOriginal = try cropImage(original, rect: crop)
            try saveSheet([cropOriginal] + order.compactMap { key in comparisons[key].flatMap { try? cropImage($0, rect: crop) } }, name + "-face-detail-comparison.png", output, columns: 3)
            let detailTiles = try ([original] + order.map { comparisons[$0]! }).map { try cropImage($0, rect: crop) }
            try saveLabeledSheet(Array(zip(labels, detailTiles)), name + "-face-detail-review.png", output, columns: 2)
        }
        try runPerformanceMatrix(fixtures: fixtures, output: output, context: context)
        try runMaskAlignmentDiagnostics(fixtures: fixtures, output: output, context: context)
        try runSyntheticMotionSequence(fixtures: fixtures, output: output, context: context)
        try report.write(to: output.appendingPathComponent("skin-quality-metrics.csv"), atomically: true, encoding: .utf8)
        try sampleReport.write(to: output.appendingPathComponent("skin-processing-samples.csv"), atomically: true, encoding: .utf8)
    }
    static func render(_ image: CIImage, context: CIContext) throws -> CGImage { guard let cg = context.createCGImage(image, from:image.extent) else { throw NSError(domain:"SkinQualityAudit", code:2) }; return cg }
    static func save(_ image: CGImage, _ name: String, _ directory: URL) throws { let url=directory.appendingPathComponent(name); guard let d=CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,1,nil) else { throw NSError(domain:"SkinQualityAudit",code:3) }; CGImageDestinationAddImage(d,image,nil); guard CGImageDestinationFinalize(d) else { throw NSError(domain:"SkinQualityAudit",code:4) } }
    static func cropImage(_ image: CGImage, rect: CGRect) throws -> CGImage { guard let cropped=image.cropping(to:rect.integral) else { throw NSError(domain:"SkinQualityAudit",code:7) }; return cropped }
    static func resize(_ image: CIImage, width: Int, height: Int) -> CIImage {
        let e = image.extent
        return image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / e.width, y: CGFloat(height) / e.height))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }
    static func maskCoverage(_ image: CGImage, faceRects: [CGRect]) throws -> (faceCoveragePct: Double, faceMeanAlpha: Double, outsideCoveragePct: Double) {
        let pixels = try rgbPixels(image), width = image.width, height = image.height
        var faceCount = 0.0, faceCovered = 0.0, faceAlpha = 0.0, outsideCount = 0.0, outsideCovered = 0.0
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            let alpha = Double(pixels[i]) / 255.0
            if faceRects.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) {
                faceCount += 1; faceAlpha += alpha; if alpha > 0.02 { faceCovered += 1 }
            } else { outsideCount += 1; if alpha > 0.02 { outsideCovered += 1 } }
        } }
        return (100 * faceCovered / max(faceCount, 1), faceAlpha / max(faceCount, 1), 100 * outsideCovered / max(outsideCount, 1))
    }
    static func maskedMeanAbsoluteDifference(_ a:[UInt8],_ b:[UInt8],mask:CGImage)throws->Double {
        let m=try rgbPixels(mask),pixels=min(a.count,b.count)/4
        guard m.count/4==pixels else { return 0 }
        var total=0.0,weight=0.0
        for pixel in 0..<pixels {
            let i=pixel*4,alpha=Double(m[i])/255
            guard alpha>0.02 else { continue }
            total += alpha * (Double(abs(Int(a[i])-Int(b[i])))+Double(abs(Int(a[i+1])-Int(b[i+1])))+Double(abs(Int(a[i+2])-Int(b[i+2]))))/3
            weight += alpha
        }
        return total/max(weight,1)
    }
    static func saveLabeledSheet(_ tiles: [(String, CGImage)], _ name: String, _ directory: URL, columns: Int) throws {
        guard let first = tiles.first?.1 else { return }
        let columns = max(1, columns), caption: CGFloat = 34
        let rows = (tiles.count + columns - 1) / columns
        let width = first.width * columns, height = (first.height + Int(caption)) * rows
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        for (index, tile) in tiles.enumerated() {
            let col = index % columns, row = index / columns
            let x = col * first.width, y = row * (first.height + Int(caption))
            NSImage(cgImage: tile.1, size: NSSize(width: first.width, height: first.height))
                .draw(in: NSRect(x: x, y: y + Int(caption), width: first.width, height: first.height))
            (tile.0 as NSString).draw(at: NSPoint(x: x + 10, y: y + 8), withAttributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.black
            ])
        }
        graphics.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { throw NSError(domain: "SkinQualityAudit", code: 11) }
        try save(cg, name, directory)
    }
    static func saveSheet(_ images:[CGImage],_ name:String,_ directory:URL,columns:Int)throws { guard let first=images.first else{return}; let columns=max(1,columns); let rows=(images.count+columns-1)/columns; let width=first.width*columns,height=first.height*rows; var bytes=[UInt8](repeating:255,count:width*height*4); let result:CGImage?=bytes.withUnsafeMutableBytes { raw in guard let c=CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return nil}; c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(x:0,y:0,width:width,height:height)); for (i,image) in images.enumerated(){ let col=i%columns,row=i/columns; c.draw(image,in:CGRect(x:col*first.width,y:height-(row+1)*first.height,width:first.width,height:first.height)) }; return c.makeImage() }; guard let result else{throw NSError(domain:"SkinQualityAudit",code:8)}; try save(result,name,directory) }
    static func rgbPixels(_ image: CGImage) throws -> [UInt8] { let w=image.width,h=image.height; var bytes=[UInt8](repeating:0,count:w*h*4); bytes.withUnsafeMutableBytes { raw in let c=CGContext(data:raw.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!; c.draw(image,in:CGRect(x:0,y:0,width:w,height:h)) }; return bytes }
    static func pixelDiff(_ a:[UInt8],_ b:[UInt8],width:Int,height:Int,faceRects:[CGRect])->(face:Double,nonface:Double,faceSigned:Double,nonfaceSigned:Double) {
        var fs=0.0,fc=0.0,ns=0.0,nc=0.0,fsg=0.0,nsg=0.0
        let pixelCount=min(a.count,b.count)/4
        for pixel in 0..<pixelCount {
            let x=pixel%width,y=pixel/width
            guard y<height else { break }
            let isFace=faceRects.contains{$0.contains(CGPoint(x:x,y:y))},i=pixel*4
            let d=(Double(abs(Int(a[i])-Int(b[i])))+Double(abs(Int(a[i+1])-Int(b[i+1])))+Double(abs(Int(a[i+2])-Int(b[i+2]))))/3
            let signed=(Double(Int(b[i])-Int(a[i]))+Double(Int(b[i+1])-Int(a[i+1]))+Double(Int(b[i+2])-Int(a[i+2])))/3
            if isFace {fs += d;fc += 1;fsg += signed} else {ns += d;nc += 1;nsg += signed}
        }
        return (fs/max(fc,1),ns/max(nc,1),fsg/max(fc,1),nsg/max(nc,1))
    }
    static func makePool(width:Int,height:Int)throws->CVPixelBufferPool { let a:[CFString:Any]=[kCVPixelBufferWidthKey:width,kCVPixelBufferHeightKey:height,kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,kCVPixelBufferIOSurfacePropertiesKey:[:] as CFDictionary]; var p:CVPixelBufferPool?; guard CVPixelBufferPoolCreate(kCFAllocatorDefault,nil,a as CFDictionary,&p)==kCVReturnSuccess,let p else {throw NSError(domain:"SkinQualityAudit",code:5)}; return p }
    static func makeBuffer(_ image:CIImage,pool:CVPixelBufferPool,context:CIContext)throws->CVPixelBuffer { var b:CVPixelBuffer?; guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,pool,&b)==kCVReturnSuccess,let b else {throw NSError(domain:"SkinQualityAudit",code:6)}; let bounds=CGRect(x:0,y:0,width:CVPixelBufferGetWidth(b),height:CVPixelBufferGetHeight(b)); context.render(image,to:b,bounds:bounds,colorSpace:CGColorSpaceCreateDeviceRGB()); return b }
    static func cameraFrame(_ image:CIImage,width:Int,height:Int)->CIImage { let e=image.extent; let scale=max(CGFloat(width)/e.width,CGFloat(height)/e.height); let scaled=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale)); let s=scaled.extent; return scaled.transformed(by:CGAffineTransform(translationX:-s.minX+(CGFloat(width)-s.width)/2,y:-s.minY+(CGFloat(height)-s.height)/2)).cropped(to:CGRect(x:0,y:0,width:width,height:height)) }
    static func percentile(_ x:[Double],_ p:Double)->Double { x[min(x.count-1,Int(Double(x.count-1)*p))] }
    static func fmt(_ x:Double)->String { String(format:"%.3f",x) }
    static func runPerformanceMatrix(fixtures:URL,output:URL,context:CIContext)throws {
        let sourceCG=try loadDownsampledImage(at:fixtures.appendingPathComponent("Portrait-CC0.jpg"),maximumDimension:1920)
        var rows="quality,width,height,effect,background,segmentation_p50_ms,segmentation_p95_ms,segmentation_max_ms,compositing_p50_ms,compositing_p95_ms,compositing_max_ms,total_p50_ms,total_p95_ms,total_max_ms,fallbacks,samples\n"
        let dimensions=[(640,480),(1280,720),(1920,1080)]
        let effects:[(String,Double)]=[("off",0),("subtle",0.16),("refined",0.30)]
        for (width,height) in dimensions {
            let pool=try makePool(width:width,height:height)
            let frame=cameraFrame(CIImage(cgImage:sourceCG),width:width,height:height)
            let input=try makeBuffer(frame,pool:pool,context:context)
            for (effect,intensity) in effects {
                let backgrounds:[(String,BackgroundTreatment)]=[("solid",.solid(BackgroundReplacementProcessor.neutralColor)),("blur",.blur(radius:16))]
                for (background,treatment) in backgrounds {
                    let processor=BackgroundReplacementProcessor(quality:.balanced,maskFeatherRadius:1.1)
                    var seg=[Double](),comp=[Double](),total=[Double](),fallbacks=0
                    for index in 0..<23 {
                        let result=processor.process(pixelBuffer:input,outputPool:pool,treatment:treatment,skinRefinementIntensity:intensity)
                        if result.usedNeutralFallback { fallbacks += 1 }
                        if index>=3 { seg.append(result.segmentationMilliseconds); comp.append(result.compositingMilliseconds); total.append(result.segmentationMilliseconds+result.compositingMilliseconds) }
                    }
                    func stats(_ values:[Double])->(Double,Double,Double) { let sorted=values.sorted(); return (percentile(sorted,0.5),percentile(sorted,0.95),sorted.last ?? 0) }
                    let s=stats(seg),c=stats(comp),t=stats(total)
                    rows += "balanced,\(width),\(height),\(effect),\(background),\(fmt(s.0)),\(fmt(s.1)),\(fmt(s.2)),\(fmt(c.0)),\(fmt(c.1)),\(fmt(c.2)),\(fmt(t.0)),\(fmt(t.1)),\(fmt(t.2)),\(fallbacks),20\n"
                    print("performance quality=balanced size=\(width)x\(height) effect=\(effect) background=\(background) total_p50_p95_max=\(fmt(t.0))/\(fmt(t.1))/\(fmt(t.2)) fallbacks=\(fallbacks)")
                }
            }
        }
        try rows.write(to:output.appendingPathComponent("balanced-processing-performance.csv"),atomically:true,encoding:.utf8)
    }
    static func runMaskAlignmentDiagnostics(fixtures:URL,output:URL,context:CIContext)throws {
        let sourceCG=try loadDownsampledImage(at:fixtures.appendingPathComponent("Portrait-CC0.jpg"),maximumDimension:1920)
        let dimensions=[(640,480),(1280,720),(480,640),(1920,1080)]
        let qualities:[(String,SegmentationQuality)]=[("Fast",.fast),("Balanced",.balanced),("Accurate",.accurate)]
        var rows="width,height,quality,mask_width,mask_height,mask_origin_x,mask_origin_y,mask_aspect,output_aspect,scale_x,scale_y,blur_composite_fallback\n"
        for (width,height) in dimensions {
            let pool=try makePool(width:width,height:height)
            let source=cameraFrame(CIImage(cgImage:sourceCG),width:width,height:height)
            let buffer=try makeBuffer(source,pool:pool,context:context)
            var tiles:[(String,CGImage)]=[("Input \(width)x\(height)",try render(source,context:context))]
            var compositeTiles:[(String,CGImage)]=[("Input",try render(source,context:context))]
            for (name,quality) in qualities {
                guard let diagnostic=BackgroundReplacementProcessor.diagnosticPersonMask(for:buffer,quality:quality) else {
                    throw NSError(domain:"SkinQualityAudit",code:12,userInfo:[NSLocalizedDescriptionKey:"No aligned \(name) mask at \(width)x\(height)"])
                }
                let mask=diagnostic.alignedImage
                let maskCG=try render(mask,context:context)
                try save(maskCG,"person-mask-\(name.lowercased())-\(width)x\(height).png",output)
                let tint=CIImage(color:CIColor(red:0.05,green:0.9,blue:1,alpha:0.48)).cropped(to:source.extent)
                let overlay=tint.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:source,kCIInputMaskImageKey:mask]).cropped(to:source.extent)
                let overlayCG=try render(overlay,context:context)
                try save(overlayCG,"person-mask-overlay-\(name.lowercased())-\(width)x\(height).png",output)
                tiles.append(("\(name) foreground mask",overlayCG))
                let e=diagnostic.sourceExtent,t=diagnostic.transform
                var fallback="not-run"
                if width==1280 && height==720 {
                    let result=BackgroundReplacementProcessor(quality:quality,maskFeatherRadius:1.1)
                        .process(pixelBuffer:buffer,outputPool:pool,treatment:.blur(radius:24))
                    fallback=String(result.usedNeutralFallback)
                    let composite=try render(CIImage(cvPixelBuffer:result.pixelBuffer),context:context)
                    try save(composite,"blur-composite-\(name.lowercased())-1280x720.png",output)
                    compositeTiles.append(("\(name) blur composite",composite))
                }
                rows += "\(width),\(height),\(name),\(Int(e.width)),\(Int(e.height)),\(fmt(Double(e.minX))),\(fmt(Double(e.minY))),\(fmt(Double(e.width/e.height))),\(fmt(Double(width)/Double(height))),\(fmt(Double(t.a))),\(fmt(Double(t.d))),\(fallback)\n"
            }
            try saveLabeledSheet(tiles,"mask-alignment-\(width)x\(height).png",output,columns:2)
            if width==1280 && height==720 { try saveLabeledSheet(compositeTiles,"halo-composite-comparison-1280x720.png",output,columns:2) }
        }
        try rows.write(to:output.appendingPathComponent("mask-alignment.csv"),atomically:true,encoding:.utf8)
    }
    static func runSyntheticMotionSequence(fixtures:URL,output:URL,context:CIContext)throws {
        let fixture=try loadDownsampledImage(at:fixtures.appendingPathComponent("SkinTest-medium-brown.png"),maximumDimension:640)
        let base=cameraFrame(CIImage(cgImage:fixture),width:640,height:480), extent=CGRect(x:0,y:0,width:640,height:480)
        var sequences:[(String,[CIImage])]=[]
        sequences.append(("face-translation",(0..<12).map { i in base.transformed(by:CGAffineTransform(translationX:CGFloat(i-5)*5.0,y:CGFloat((i%3)-1)*2.0)).cropped(to:extent) }))
        sequences.append(("head-rotation-proxy",(0..<12).map { i in
            let angle=CGFloat(i)*0.012-0.066
            let transform=CGAffineTransform(translationX:-320,y:-240).rotated(by:angle).translatedBy(x:320,y:240)
            return base.transformed(by:transform).cropped(to:extent)
        }))
        let blank=CIImage(color:CIColor(red:0.24,green:0.27,blue:0.30)).cropped(to:extent)
        sequences.append(("temporary-disappearance",(0..<12).map { (4...7).contains($0) ? blank : base }))
        let faceSmall=try render(resize(CIImage(cgImage:fixture),width:320,height:480),context:context)
        var pairBytes=[UInt8](repeating:0,count:640*480*4), pairCG:CGImage?
        pairBytes.withUnsafeMutableBytes { raw in
            guard let pairContext=CGContext(data:raw.baseAddress,width:640,height:480,bitsPerComponent:8,bytesPerRow:640*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            pairContext.draw(faceSmall,in:CGRect(x:0,y:0,width:320,height:480)); pairContext.draw(faceSmall,in:CGRect(x:320,y:0,width:320,height:480))
            pairCG=pairContext.makeImage()
        }
        let pair=CIImage(cgImage:try { guard let pairCG else { throw NSError(domain:"SkinQualityAudit",code:13) }; return pairCG }())
        sequences.append(("two-faces",Array(repeating:pair,count:12)))
        sequences.append(("lighting-change",(0..<12).map { i in base.applyingFilter("CIColorControls",parameters:[kCIInputBrightnessKey:CGFloat(i)*0.025-0.1375]) }))
        sequences.append(("rapid-motion",(0..<12).map { i in base.transformed(by:CGAffineTransform(translationX:(i%2 == 0 ? -32 : 32),y:(i%2 == 0 ? -7 : 7))).cropped(to:extent) }))
        sequences.append(("static-repeat-control",Array(repeating:base,count:12)))
        let sequenceDir=output.appendingPathComponent("motion-sequences",isDirectory:true)
        try FileManager.default.createDirectory(at:sequenceDir,withIntermediateDirectories:true)
        var rows="scenario,frame,intensity,detected_faces,mask_mean_alpha,output_vs_input_mae_rgb,processing_ms,face_absent_identity\n"
        for (scenario,frames) in sequences {
            var sheet:[(String,CGImage)]=[]
            for (index,frame) in frames.enumerated() {
                let faceRequest=VNDetectFaceLandmarksRequest()
                try VNImageRequestHandler(ciImage:frame,options:[:]).perform([faceRequest])
                let faceCount=faceRequest.results?.count ?? 0
                for (label,strength) in [("subtle",0.16),("refined",0.30)] {
                    let start=DispatchTime.now().uptimeNanoseconds
                    let result=NaturalSkinRetouch.apply(to:frame,intensity:strength)
                    guard let rendered=context.createCGImage(result,from:extent) else { throw NSError(domain:"SkinQualityAudit",code:14) }
                    let elapsed=Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
                    guard let inputCG=context.createCGImage(frame,from:extent) else { throw NSError(domain:"SkinQualityAudit",code:15) }
                    let d=pixelDiff(try rgbPixels(inputCG),try rgbPixels(rendered),width:640,height:480,faceRects:[extent])
                    let mask=NaturalSkinRetouch.diagnosticMask(for:frame,intensity:strength)
                    var alpha=0.0
                    if let mask,let maskCG=try? render(mask,context:context),let stats=try? maskCoverage(maskCG,faceRects:[extent]) { alpha=stats.faceMeanAlpha }
                    rows += "\(scenario),\(index),\(label),\(faceCount),\(fmt(alpha)),\(fmt(d.face)),\(fmt(elapsed)),\(faceCount == 0 && imagesEqual(inputCG,rendered))\n"
                    if index == 5 || index == 6 || index == 7 {
                        if label == "subtle" { sheet.append(("\(label) frame \(index)",rendered)) }
                    }
                    if index == 6 && label == "subtle" { sheet.insert(("Input frame \(index)",inputCG),at:0) }
                    if index == 6 && label == "refined" { sheet.append(("refined frame \(index)",rendered)) }
                }
            }
            try saveLabeledSheet(sheet,scenario+"-review.png",sequenceDir,columns:2)
        }
        try rows.write(to:sequenceDir.appendingPathComponent("synthetic-motion.csv"),atomically:true,encoding:.utf8)
    }
    static func imagesEqual(_ left:CGImage,_ right:CGImage)->Bool {
        guard let a=left.dataProvider?.data as Data?,let b=right.dataProvider?.data as Data? else { return false }
        return a==b
    }
}
