import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import PrivateCamSegmentation

@main enum SkinCalibrationAudit {
    static let names = ["SkinTest-medium-brown", "SkinTest-light-textured", "SkinTest-deep-lowkey", "SkinTest-light-medium"]
    static let conditions = ["normal-texture", "mild-sensor-noise", "uneven-light", "low-light-grain", "webcam-jpeg"]
    static let labels = ["Original", "Off", "Build 18 Subtle", "Approved Subtle", "Build 18 Refined", "Approved Refined"]
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("usage: skin-calibration-audit fixture-directory output-directory") }
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var participantTiles: [(String, CGImage)] = [], detailTiles: [(String, CGImage)] = []
        var metrics = "portrait,condition,treatment,noise_level,sharpness,blend_scale,skin_mae_vs_off,frame_mae_vs_off,face_mae_to_ideal_condition\n"
        for name in names {
            let fixture = try decode(fixtures.appendingPathComponent(name + ".png"))
            for condition in conditions {
                let sourceCG = try cameraVariant(fixture, condition: condition, seed: names.firstIndex(of: name)! * 101 + conditions.firstIndex(of: condition)!)
                let idealCG = condition == "mild-sensor-noise" || condition == "webcam-jpeg" ? fixture
                    : (condition == "low-light-grain" ? try cameraVariant(fixture, condition: condition, seed: 1, includeNoise: false) : sourceCG)
                let source = CIImage(cgImage: sourceCG)
                let faceRequest = VNDetectFaceLandmarksRequest()
                try VNImageRequestHandler(cgImage: sourceCG, options: [:]).perform([faceRequest])
                guard let face = faceRequest.results?.first else { throw NSError(domain: "Calibration", code: 1, userInfo: [NSLocalizedDescriptionKey: "No face in \(name)/\(condition)"]) }
                let images: [CGImage] = [
                    sourceCG,
                    try render(NaturalSkinRetouch.apply(to: source, intensity: 0)),
                    try render(NaturalSkinRetouch.applyForCalibration(to: source, intensity: 0.16, noiseLevel: 0.03, sharpness: 0.65, blendScale: 1.0)),
                    try render(NaturalSkinRetouch.apply(to: source, intensity: 0.16)),
                    try render(NaturalSkinRetouch.applyForCalibration(to: source, intensity: 0.30, noiseLevel: 0.03, sharpness: 0.65, blendScale: 1.0)),
                    try render(NaturalSkinRetouch.apply(to: source, intensity: 0.30))
                ]
                let prefix = "\(name)-\(condition)"
                let participantForCondition = try images.map { try participantFrame($0) }
                let detailForCondition = try images.map { try faceDetail($0, observation: face, sourceSize: sourceCG) }
                try saveSheet(Array(zip(labels.map { "\(condition) · \($0)" }, participantForCondition)),
                              "\(prefix)-participant-comparison.png", output, columns: 6, tileWidth: 320, tileHeight: 180)
                try saveSheet(Array(zip(labels.map { "\(condition) · \($0)" }, detailForCondition)),
                              "\(prefix)-face-detail-comparison.png", output, columns: 6, tileWidth: 360, tileHeight: 360)
                for (label, image) in zip(labels, images) {
                    try save(image, "\(prefix)-\(slug(label)).png", output)
                    let participant = participantForCondition[labels.firstIndex(of: label)!]
                    participantTiles.append(("\(name.replacingOccurrences(of: "SkinTest-", with: "")) · \(condition) · \(label)", participant))
                    let detail = detailForCondition[labels.firstIndex(of: label)!]
                    detailTiles.append(("\(name.replacingOccurrences(of: "SkinTest-", with: "")) · \(condition) · \(label)", detail))
                    let comparedToOff = metricsFor(images[1], image, face: face, width: sourceCG.width, height: sourceCG.height)
                    let idealError = metricsFor(idealCG, image, face: face, width: sourceCG.width, height: sourceCG.height).skin
                    metrics += "\(name),\(condition),\(label),\(label.contains("Approved") ? "0.06" : (label.contains("Build 18") ? "0.03" : "")),\(label.contains("Approved") ? "0.82" : (label.contains("Build 18") ? "0.65" : "")),\(label == "Approved Refined" ? "1.08" : (label.contains("Approved") ? "1.00" : "")),\(fmt(comparedToOff.skin)),\(fmt(comparedToOff.frame)),\(fmt(idealError))\n"
                }
                print("Rendered \(prefix): 6 treatments at 320x180 and enlarged face detail")
            }
        }
        try saveSheet(participantTiles, "contact-sheet-participant-320x180.png", output, columns: 6, tileWidth: 320, tileHeight: 180)
        try saveSheet(detailTiles, "contact-sheet-face-detail.png", output, columns: 6, tileWidth: 360, tileHeight: 360)
        try metrics.write(to: output.appendingPathComponent("calibration-metrics.csv"), atomically: true, encoding: .utf8)
        let readme = """
        # Directive 020E visual calibration

        Comparison basis: four documented synthetic adult portraits, no personal camera images. Five deterministic input conditions were generated locally: normal texture (original fixture), mild sensor noise, uneven lighting, low-light grain, and moderate JPEG compression.

        Current Build 18: CINoiseReduction noiseLevel=0.03, sharpness=0.65; blend scale=1. Approved production settings: noiseLevel=0.06, sharpness=0.82; blend scale=1.00 for Subtle and 1.08 for Refined. Preset strengths remain 0.16 and 0.30. Mask feather remains 1.25 pixels.

        Both sheets are labeled. Participant sheet tiles are actual 320x180 camera-call framing. Face-detail tiles use the detected face crop enlarged to 360x360. `calibration-metrics.csv` reports pixel differences from Off within the face bounding box as diagnostics, not aesthetic acceptance criteria.

        Product-owner selection: Approved Subtle and Approved Refined.
        """
        try readme.write(to: output.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }

    static func cameraVariant(_ image: CGImage, condition: String, seed: Int, includeNoise: Bool = true) throws -> CGImage {
        if condition == "webcam-jpeg" {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw NSError(domain: "Calibration", code: 2) }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.62] as CFDictionary)
            guard CGImageDestinationFinalize(destination), let source = CGImageSourceCreateWithData(data, nil), let jpeg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw NSError(domain: "Calibration", code: 3) }
            return jpeg
        }
        let width = image.width, height = image.height
        var bytes = pixels(image)
        var state = UInt64(seed + 1) &* 6364136223846793005 &+ 1442695040888963407
        func randomSigned() -> Double { state = state &* 2862933555777941757 &+ 3037000493; return Double((state >> 33) & 0xffff) / 32767.5 - 1 }
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            var lighting = 1.0
            if condition == "uneven-light" { lighting = 0.72 + 0.38 * Double(x) / Double(max(width - 1, 1)) + 0.08 * (1 - Double(y) / Double(max(height - 1, 1))) }
            let low = condition == "low-light-grain"
            let scale = low ? 0.62 : lighting
            let noise = includeNoise ? (condition == "mild-sensor-noise" ? 4.0 : (low ? 10.0 : 0.0)) : 0.0
            for c in 0..<3 {
                let value = Double(bytes[i+c]) * scale + randomSigned() * noise
                bytes[i+c] = UInt8(min(max(Int(value.rounded()), 0), 255))
            }
        } }
        return try imageFromPixels(bytes, width: width, height: height)
    }
    static func decode(_ url: URL) throws -> CGImage { guard let s=CGImageSourceCreateWithURL(url as CFURL,nil), let i=CGImageSourceCreateImageAtIndex(s,0,nil) else { throw NSError(domain:"Calibration",code:4) }; return i }
    static func render(_ image: CIImage) throws -> CGImage { guard let cg=context.createCGImage(image,from:image.extent) else { throw NSError(domain:"Calibration",code:5) }; return cg }
    static func pixels(_ image: CGImage) -> [UInt8] { var b=[UInt8](repeating:0,count:image.width*image.height*4); b.withUnsafeMutableBytes { raw in let c=CGContext(data:raw.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!; c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height)) }; return b }
    static func imageFromPixels(_ b:[UInt8],width:Int,height:Int)throws->CGImage { let d=Data(b) as CFData; guard let p=CGDataProvider(data:d), let i=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:p,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { throw NSError(domain:"Calibration",code:6) }; return i }
    static func participantFrame(_ image:CGImage)throws->CGImage { let source=CIImage(cgImage:image), e=source.extent, target=CGRect(x:0,y:0,width:320,height:180), scale=max(320/e.width,180/e.height), resized=source.transformed(by:CGAffineTransform(scaleX:scale,y:scale)), r=resized.extent, centered=resized.transformed(by:CGAffineTransform(translationX:-r.minX+(320-r.width)/2,y:-r.minY+(180-r.height)/2)).cropped(to:target); return try render(centered) }
    static func faceDetail(_ image:CGImage,observation:VNFaceObservation,sourceSize:CGImage)throws->CGImage { let box=observation.boundingBox, w=CGFloat(sourceSize.width), h=CGFloat(sourceSize.height); let rect=CGRect(x:box.minX*w,y:(1-box.maxY)*h,width:box.width*w,height:box.height*h).insetBy(dx:-box.width*w*0.20,dy:-box.height*h*0.20).integral; guard let cropped=image.cropping(to:rect.intersection(CGRect(x:0,y:0,width:w,height:h))) else { return image }; let scaled=CIImage(cgImage:cropped).transformed(by:CGAffineTransform(scaleX:360/CGFloat(cropped.width),y:360/CGFloat(cropped.height))).cropped(to:CGRect(x:0,y:0,width:360,height:360)); return try render(scaled) }
    static func metricsFor(_ baseline:CGImage,_ image:CGImage,face:VNFaceObservation,width:Int,height:Int)->(skin:Double,frame:Double) { let a=pixels(baseline),b=pixels(image); var total=0.0,all=0.0,count=0.0; let box=face.boundingBox,rect=CGRect(x:box.minX*CGFloat(width),y:box.minY*CGFloat(height),width:box.width*CGFloat(width),height:box.height*CGFloat(height)); for p in 0..<(width*height) { let x=p%width,y=p/width,i=p*4,d=(abs(Int(a[i])-Int(b[i]))+abs(Int(a[i+1])-Int(b[i+1]))+abs(Int(a[i+2])-Int(b[i+2])))/3; all += Double(d); if rect.contains(CGPoint(x:x,y:y)) { total += Double(d); count += 1 } }; return (total/max(count,1),all/Double(width*height)) }
    static func save(_ image:CGImage,_ name:String,_ dir:URL)throws { guard let d=CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL,UTType.png.identifier as CFString,1,nil) else { throw NSError(domain:"Calibration",code:7) }; CGImageDestinationAddImage(d,image,nil); guard CGImageDestinationFinalize(d) else { throw NSError(domain:"Calibration",code:8) } }
    static func saveSheet(_ items:[(String,CGImage)],_ name:String,_ dir:URL,columns:Int,tileWidth:Int,tileHeight:Int)throws { let caption=30, rows=(items.count+columns-1)/columns, w=columns*tileWidth,h=rows*(tileHeight+caption); let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w,pixelsHigh:h,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!; let gc=NSGraphicsContext(bitmapImageRep:rep)!; NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=gc; NSColor.white.setFill(); NSBezierPath(rect:NSRect(x:0,y:0,width:w,height:h)).fill(); for (index,item) in items.enumerated(){ let x=(index%columns)*tileWidth, row=index/columns, y=row*(tileHeight+caption); NSImage(cgImage:item.1,size:NSSize(width:tileWidth,height:tileHeight)).draw(in:NSRect(x:x,y:y+caption,width:tileWidth,height:tileHeight)); (item.0 as NSString).draw(at:NSPoint(x:x+5,y:y+8),withAttributes:[.font:NSFont.systemFont(ofSize:10,weight:.medium),.foregroundColor:NSColor.black]) }; gc.flushGraphics(); NSGraphicsContext.restoreGraphicsState(); guard let cg=rep.cgImage else { throw NSError(domain:"Calibration",code:9) }; try save(cg,name,dir) }
    static func slug(_ label:String)->String { label.lowercased().replacingOccurrences(of:" ",with:"-") }
    static func fmt(_ value:Double)->String { String(format:"%.3f",value) }
}
