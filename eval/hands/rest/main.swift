// Noch nicht geprüfte Apple-Werkzeuge: Hand-Pose bei niedriger Konfidenz (mit Maske),
// Körper-Pose (Handgelenke), Bildklassifikation, Maskenschwelle.
import Foundation
import Vision
import ImageIO
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
print("datei,pose_max_maske,koerper_hand,klasse_hand,flaeche_weich,rand_weich")
for f in files {
    guard let s = CGImageSourceCreateWithURL(f as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { continue }
    let pose = VNDetectHumanHandPoseRequest(); pose.maximumHandCount = 4
    let body = VNDetectHumanBodyPoseRequest()
    let cls = VNClassifyImageRequest()
    let person = VNGeneratePersonSegmentationRequest(); person.qualityLevel = .fast
    person.outputPixelFormat = kCVPixelFormatType_OneComponent8
    try? VNImageRequestHandler(cgImage: img, options: [:]).perform([pose, body, cls, person])
    guard let m = person.results?.first?.pixelBuffer else { print("\(f.lastPathComponent),0,0,0,0,0"); continue }
    // höchste Pose-Konfidenz unter Händen mit Maske an der Hand
    var pm: Float = 0
    for h in pose.results ?? [] {
        let pts = ((try? h.recognizedPoints(.all)) ?? [:]).values.map(\.location)
        if VisionHandDetector.maskPeak(m, near: pts) >= 0.1 { pm = max(pm, h.confidence) }
    }
    // Handgelenk aus der Körper-Pose, sicher erkannt
    var wrist: Float = 0
    for b in body.results ?? [] {
        for j in [VNHumanBodyPoseObservation.JointName.leftWrist, .rightWrist] {
            if let p = try? b.recognizedPoint(j) { wrist = max(wrist, p.confidence) }
        }
    }
    let labels = (cls.results ?? []).filter { ["hand", "finger", "people", "adult", "child", "arm"].contains($0.identifier) }
    let ch = labels.map(\.confidence).max() ?? 0
    // weichere Maskenschwelle (> 30 statt > 127)
    CVPixelBufferLockBaseAddress(m, .readOnly)
    let w = CVPixelBufferGetWidth(m), hh = CVPixelBufferGetHeight(m), rb = CVPixelBufferGetBytesPerRow(m)
    let p = CVPixelBufferGetBaseAddress(m)!.assumingMemoryBound(to: UInt8.self)
    var on = 0, e = 0, eo = 0; let mx = max(1, w * 8 / 100), my = max(1, hh * 8 / 100)
    for y in 0..<hh { for x in 0..<w { let v = p[y * rb + x] > 30; if v { on += 1 }; if x < mx || x >= w - mx || y < my || y >= hh - my { e += 1; if v { eo += 1 } } } }
    CVPixelBufferUnlockBaseAddress(m, .readOnly)
    print(String(format: "%@,%.3f,%.3f,%.3f,%.4f,%.4f", f.lastPathComponent, pm, wrist, ch, Double(on) / Double(w * hh), Double(eo) / Double(e)))
}
