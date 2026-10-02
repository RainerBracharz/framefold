import SwiftUI
import UIKit

/// Der Live-Loop: die bisherigen Bilder einer laufenden Sitzung als Schleife.
/// Während Aldo faltet, wächst daneben schon der Film – im Sucher klein in
/// der Ecke, auf dem Studio-Monitor groß neben dem Kamerabild.
///
/// Bei „Bewegung reduzieren" steht statt der Schleife das jüngste Bild.
struct LiveLoopView: View {
    let frames: [Data]
    /// Abspieltempo der Schleife in Bildern pro Sekunde
    var fps: Double = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if frames.isEmpty {
            Color.clear
        } else if reduceMotion || frames.count == 1 {
            still(frames[frames.count - 1])
        } else {
            TimelineView(.periodic(from: .now, by: 1 / fps)) { context in
                // Am Ende der Serie kurz stehen bleiben (zwei Takte), damit
                // man sieht, wo der Film gerade aufhört.
                let length = frames.count + 2
                let tick = Int(context.date.timeIntervalSinceReferenceDate * fps)
                still(frames[min(tick % length, frames.count - 1)])
            }
        }
    }

    @ViewBuilder
    private func still(_ data: Data) -> some View {
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        }
    }
}
