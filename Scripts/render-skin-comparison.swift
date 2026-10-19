import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

func fail(_ message: String) -> Never { fputs("error: \(message)\n", stderr); exit(1) }
guard CommandLine.arguments.count == 3 else { fail("usage: render-skin-comparison.swift input.jpg output-directory") }
let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("could not load input image") }
let sourceImage = CIImage(cgImage: original)
let context = CIContext(options: [.cacheIntermediates: true])
let faceRequest = VNDetectFaceLandmarksRequest()
do { try VNImageRequestHandler(cgImage: original, options: [:]).perform([faceRequest]) }
catch { fail("face landmark detection failed: \(error.localizedDescription)") }
guard !(faceRequest.results ?? []).isEmpty else { fail("input contains no detectable face") }
func render(_ intensity: Double) -> CGImage {
    let image = NaturalSkinRetouch.apply(to: sourceImage, intensity: intensity)
    guard let rendered = context.createCGImage(image, from: sourceImage.extent) else { fail("could not render retouched image") }
    return rendered
}
let subtle = render(0.16)
let refined = render(0.30)
var elapsed: [Double] = []
for iteration in 0..<12 {
    let start = DispatchTime.now().uptimeNanoseconds
    _ = render(0.16)
    let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    if iteration >= 2 { elapsed.append(milliseconds) }
}
func save(_ image: CGImage, as name: String) throws {
    let destinationURL = outputURL.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("could not create \(destinationURL.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(destinationURL.path)") }
}
try save(original, as: "skin-original.png")
try save(subtle, as: "skin-subtle.png")
try save(refined, as: "skin-refined.png")
let width = original.width, height = original.height
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let bitmap = CGContext(data: nil, width: width * 2, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 8, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("could not create comparison canvas") }
bitmap.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
bitmap.draw(subtle, in: CGRect(x: width, y: 0, width: width, height: height))
guard let comparison = bitmap.makeImage() else { fail("could not create comparison image") }
try save(comparison, as: "skin-before-after.png")
let sortedElapsed = elapsed.sorted()
let p50 = sortedElapsed[sortedElapsed.count / 2]
let p95 = sortedElapsed[min(sortedElapsed.count - 1, Int(Double(sortedElapsed.count - 1) * 0.95))]
print("Offline supplied portrait fixture; 512x512 native size. Subtle Vision + mask + render p50/p95: \(String(format: "%.2f", p50))/\(String(format: "%.2f", p95)) ms over \(sortedElapsed.count) warmed runs. Output: subtle, refined, and side-by-side PNGs.")
