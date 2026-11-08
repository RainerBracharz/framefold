// Prüft die Handerkennung genau so, wie sie in der App steckt (FrameFold/HandDetector.swift).
import Foundation
import ImageIO
let d = VisionHandDetector()
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
let t0 = Date()
for f in files {
    guard let s = CGImageSourceCreateWithURL(f as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { continue }
    print("\(f.lastPathComponent),\(d.containsHands(cgImage: img, confidence: 0.3) ? 1 : 0)")
}
FileHandle.standardError.write("ms je Bild: \(Int(Date().timeIntervalSince(t0) * 1000) / max(1, files.count))\n".data(using: .utf8)!)
