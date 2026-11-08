// Prüfprogramm für die Handerkennung (macOS, Vision).
// Aufruf: swiftc -O handcheck.swift -o bin/handcheck && bin/handcheck <ordner> > ergebnis.csv
// Je Bild: höchste Konfidenz der Hand-Pose-Erkennung in mehreren Varianten
// und der Anteil der Bildfläche, den Apples Personen-Segmentierung als Mensch sieht.
import Foundation
import Vision
import CoreImage
import AppKit

let ctx = CIContext()

func loadCG(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

/// höchste Konfidenz und Anzahl sicherer Gelenke der besten Hand
func pose(_ img: CGImage) -> (Float, Int) {
    let r = VNDetectHumanHandPoseRequest(); r.maximumHandCount = 4
    try? VNImageRequestHandler(cgImage: img, options: [:]).perform([r])
    var best: Float = 0; var joints = 0
    for o in r.results ?? [] {
        if o.confidence > best {
            best = o.confidence
            joints = ((try? o.recognizedPoints(.all)) ?? [:]).values.filter { $0.confidence > 0.3 }.count
        }
    }
    return (best, joints)
}

/// Bild verkleinert in die Mitte einer doppelt so großen grauen Fläche:
/// riesige Nahaufnahme-Hände werden für die Erkennung „normal groß“.
func padded(_ img: CGImage) -> CGImage? {
    let w = img.width * 2, h = img.height * 2
    guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    c.setFillColor(CGColor(gray: 0.5, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    c.draw(img, in: CGRect(x: img.width / 2, y: img.height / 2, width: img.width, height: img.height))
    return c.makeImage()
}

/// Kontrast und Schärfe anheben (blasses Archivmaterial, Gegenlicht)
func boosted(_ img: CGImage) -> CGImage? {
    var ci = CIImage(cgImage: img)
    ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.5])
    ci = ci.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2.0, kCIInputIntensityKey: 0.6])
    return ctx.createCGImage(ci, from: ci.extent)
}

/// Anteil „Mensch“ laut Personen-Segmentierung (0…1) und Anteil am Bildrand
func person(_ img: CGImage) -> (Double, Double) {
    let r = VNGeneratePersonSegmentationRequest()
    r.qualityLevel = .balanced
    r.outputPixelFormat = kCVPixelFormatType_OneComponent8
    try? VNImageRequestHandler(cgImage: img, options: [:]).perform([r])
    guard let pb = r.results?.first?.pixelBuffer else { return (0, 0) }
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    var on = 0, edge = 0, edgeOn = 0
    let m = max(2, w / 12)
    for y in 0..<h { for x in 0..<w {
        let v = p[y * bpr + x] > 127
        if v { on += 1 }
        if x < m || x >= w - m || y < m || y >= h - m { edge += 1; if v { edgeOn += 1 } }
    } }
    return (Double(on) / Double(w * h), Double(edgeOn) / Double(max(1, edge)))
}

/// Pose auf vier überlappenden Ausschnitten (je 60 % der Kante): kleine
/// oder angeschnittene Hände in den Ecken werden größer.
func poseTiles(_ img: CGImage) -> Float {
    let w = img.width, h = img.height, tw = Int(Double(w) * 0.6), th = Int(Double(h) * 0.6)
    var best: Float = 0
    for (x, y) in [(0, 0), (w - tw, 0), (0, h - th), (w - tw, h - th)] {
        if let c = img.cropping(to: CGRect(x: x, y: y, width: tw, height: th)) { best = max(best, pose(c).0) }
    }
    return best
}

func personQ(_ img: CGImage, _ q: VNGeneratePersonSegmentationRequest.QualityLevel) -> Double { personQE(img, q).0 }
/// Fläche und Anteil des Bildrands (äußere 8 %), den die Maske berührt
func personQE(_ img: CGImage, _ q: VNGeneratePersonSegmentationRequest.QualityLevel) -> (Double, Double) {
    let r = VNGeneratePersonSegmentationRequest()
    r.qualityLevel = q
    r.outputPixelFormat = kCVPixelFormatType_OneComponent8
    try? VNImageRequestHandler(cgImage: img, options: [:]).perform([r])
    guard let pb = r.results?.first?.pixelBuffer else { return (0, 0) }
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    var on = 0, edge = 0, edgeOn = 0
    let mx = max(1, w * 8 / 100), my = max(1, h * 8 / 100)
    for y in 0..<h { for x in 0..<w {
        let v = p[y * bpr + x] > 127
        if v { on += 1 }
        if x < mx || x >= w - mx || y < my || y >= h - my { edge += 1; if v { edgeOn += 1 } }
    } }
    return (Double(on) / Double(w * h), Double(edgeOn) / Double(max(1, edge)))
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let files = (try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
    .filter { ["jpg", "png"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
print("datei,pose,gelenke,pose_rand,pose_kontrast,person,person_rand,pose_kacheln,person_genau,person_schnell,schnell_rand")
for f in files {
    guard let img = loadCG(f) else { continue }
    let (c0, j0) = pose(img)
    let cp = padded(img).map { pose($0).0 } ?? 0
    let cb = boosted(img).map { pose($0).0 } ?? 0
    let (pf, pe) = person(img)
    let pt = poseTiles(img); let pa = personQ(img, .accurate); let (pq, pqe) = personQE(img, .fast)
    print(String(format: "%@,%.3f,%d,%.3f,%.3f,%.4f,%.4f,%.3f,%.4f,%.4f,%.4f", f.lastPathComponent, c0, j0, cp, cb, pf, pe, pt, pa, pq, pqe))
}
