// Zusatzmerkmal: Wie „gefüllt" ist die Fläche unter der schnellen Personenmaske?
// Eine echte Hand ist eine Fläche mit eigener Helligkeit, eine Strichzeichnung
// besteht fast nur aus Hintergrund.
import Foundation
import ImageIO
import Vision
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
print("file,fill20,fill35,fill50,maskStd,bgStd,maskN")
for f in files {
    guard let s = CGImageSourceCreateWithURL(f as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { continue }
    let fast = VNGeneratePersonSegmentationRequest(); fast.qualityLevel = .fast; fast.outputPixelFormat = kCVPixelFormatType_OneComponent8
    try? VNImageRequestHandler(cgImage: img, options: [:]).perform([fast])
    guard let m = fast.results?.first?.pixelBuffer else { print("\(f.lastPathComponent),0,0,0,0,0,0"); continue }
    CVPixelBufferLockBaseAddress(m, .readOnly)
    let w = CVPixelBufferGetWidth(m), h = CVPixelBufferGetHeight(m), rb = CVPixelBufferGetBytesPerRow(m)
    let mp = CVPixelBufferGetBaseAddress(m)!.assumingMemoryBound(to: UInt8.self)
    var gray = [UInt8](repeating: 0, count: w * h)
    let ctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.interpolationQuality = .low
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var inside: [Int] = [], outside: [Int] = []
    for y in 0..<h { for x in 0..<w { if mp[y * rb + x] > 127 { inside.append(Int(gray[y * w + x])) } else { outside.append(Int(gray[y * w + x])) } } }
    CVPixelBufferUnlockBaseAddress(m, .readOnly)
    guard inside.count > 20, outside.count > 20 else { print("\(f.lastPathComponent),0,0,0,0,0,\(inside.count)"); continue }
    let bg = outside.sorted()[outside.count / 2]
    func fill(_ t: Int) -> Double { Double(inside.filter { abs($0 - bg) > t }.count) / Double(inside.count) }
    func sd(_ a: [Int]) -> Double { let mu = Double(a.reduce(0, +)) / Double(a.count); return (a.map { pow(Double($0) - mu, 2) }.reduce(0, +) / Double(a.count)).squareRoot() }
    print(String(format: "%@,%.3f,%.3f,%.3f,%.1f,%.1f,%d", f.lastPathComponent, fill(20), fill(35), fill(50), sd(inside), sd(outside), inside.count))
}
