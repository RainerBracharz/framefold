// Je Bild und erkannter Hand: Konfidenz, Größe der Gelenk-Hülle (Anteil an der
// längeren Bildkante) und Abstand zum nächsten Bildrand (Anteil). Dazu die
// Segmentierungswerte wie in der App.
import Foundation
import Vision
import ImageIO
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
print("datei,conf,groesse,rand,flaeche,segrand,maskhand")
for f in files {
    guard let s = CGImageSourceCreateWithURL(f as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { continue }
    let pose = VNDetectHumanHandPoseRequest(); pose.maximumHandCount = 4
    let person = VNGeneratePersonSegmentationRequest(); person.qualityLevel = .fast
    person.outputPixelFormat = kCVPixelFormatType_OneComponent8
    try? VNImageRequestHandler(cgImage: img, options: [:]).perform([pose, person])
    var (area, edge) = (0.0, 0.0)
    if let m = person.results?.first?.pixelBuffer { (area, edge) = VisionHandDetector.coverage(m) }
    let ar = Double(img.width) / Double(img.height)
    var best: (Float, Double, Double) = (0, 0, 1)
    var maskHand = 0.0
    let mbuf = person.results?.first?.pixelBuffer
    func maskAt(_ x: Double, _ y: Double) -> Double {   // höchster Maskenwert im Umkreis von 4 % der Kante
        guard let m = mbuf else { return 0 }
        CVPixelBufferLockBaseAddress(m, .readOnly); defer { CVPixelBufferUnlockBaseAddress(m, .readOnly) }
        let w = CVPixelBufferGetWidth(m), h = CVPixelBufferGetHeight(m), rb = CVPixelBufferGetBytesPerRow(m)
        let p = CVPixelBufferGetBaseAddress(m)!.assumingMemoryBound(to: UInt8.self)
        let cx = Int(x * Double(w)), cy = Int((1 - y) * Double(h)), r = max(1, w / 25)
        var mx: UInt8 = 0
        for yy in max(0, cy - r)..<min(h, cy + r + 1) { for xx in max(0, cx - r)..<min(w, cx + r + 1) { mx = max(mx, p[yy * rb + xx]) } }
        return Double(mx) / 255
    }
    for o in pose.results ?? [] {
        let pts = ((try? o.recognizedPoints(.all)) ?? [:]).values.filter { $0.confidence > 0.3 }
        guard !pts.isEmpty else { continue }
        let xs = pts.map { Double($0.location.x) }, ys = pts.map { Double($0.location.y) }
        let w = (xs.max()! - xs.min()!) * max(1, ar), h = (ys.max()! - ys.min()!) * max(1, 1 / ar)
        let size = max(w, h) / max(ar, 1)
        let rand = min(xs.min()!, ys.min()!, 1 - xs.max()!, 1 - ys.max()!)
        if o.confidence > best.0 {
            best = (o.confidence, size, rand)
            let all = ((try? o.recognizedPoints(.all)) ?? [:]).values
            maskHand = all.map { maskAt(Double($0.location.x), Double($0.location.y)) }.max() ?? 0
        }
    }
    print(String(format: "%@,%.3f,%.3f,%.3f,%.4f,%.4f,%.3f", f.lastPathComponent, best.0, best.1, best.2, area, edge, maskHand))
}
