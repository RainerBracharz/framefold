// Prüft Zeitpunkte eines Videos mit dem echten App-Detektor, Bilder wie in
// der App über AVAssetImageGenerator mit höchstens 640 px.
// Aufruf: bin/videocheck video.mp4 fenster.json > video.csv
import Foundation
import AVFoundation
let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let wins = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [[Double]]
let times = Array(Set(wins.flatMap { $0 })).sorted()
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.maximumSize = CGSize(width: 640, height: 640)
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero
let d = VisionHandDetector()
print("t,hand")
for t in times {
    guard let img = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) else { continue }
    print(String(format: "%.3f,%d", t, d.containsHands(cgImage: img, confidence: 0.3) ? 1 : 0))
}
