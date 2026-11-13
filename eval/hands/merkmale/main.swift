// Merkmale je Bild: Hand-Pose (Anzahl, höchste Konfidenz, Maskenwert an der Hand),
// Personenmaske schnell und ausgewogen (Fläche, Rand).
import Foundation
import ImageIO
import Vision
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
print("file,app,nPose,maxConf,peakFast,areaFast,edgeFast,areaBal,edgeBal,peakBal")
let d = VisionHandDetector()
for f in files {
    guard let s = CGImageSourceCreateWithURL(f as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { continue }
    let pose = VNDetectHumanHandPoseRequest(); pose.maximumHandCount = 2
    let fast = VNGeneratePersonSegmentationRequest(); fast.qualityLevel = .fast; fast.outputPixelFormat = kCVPixelFormatType_OneComponent8
    let bal = VNGeneratePersonSegmentationRequest(); bal.qualityLevel = .balanced; bal.outputPixelFormat = kCVPixelFormatType_OneComponent8
    let h = VNImageRequestHandler(cgImage: img, options: [:])
    try? h.perform([pose, fast, bal])
    let hands = pose.results ?? []
    let box = VisionHandDetector.contentBox(img)
    var peakF = 0.0, peakB = 0.0, maxC: Float = 0
    for hand in hands {
        maxC = max(maxC, hand.confidence)
        let pts = ((try? hand.recognizedPoints(.all)) ?? [:]).values.map(\.location)
        if let m = fast.results?.first?.pixelBuffer { peakF = max(peakF, VisionHandDetector.maskPeak(m, near: pts)) }
        if let m = bal.results?.first?.pixelBuffer { peakB = max(peakB, VisionHandDetector.maskPeak(m, near: pts)) }
    }
    var aF = 0.0, eF = 0.0, aB = 0.0, eB = 0.0
    if let m = fast.results?.first?.pixelBuffer { (aF, eF) = VisionHandDetector.coverage(m, content: box) }
    if let m = bal.results?.first?.pixelBuffer { (aB, eB) = VisionHandDetector.coverage(m, content: box) }
    let app = d.containsHands(cgImage: img, confidence: 0.3) ? 1 : 0
    print(String(format: "%@,%d,%d,%.2f,%.2f,%.3f,%.3f,%.3f,%.3f,%.2f", f.lastPathComponent, app, hands.count, maxC, peakF, aF, eF, aB, eB, peakB))
}
