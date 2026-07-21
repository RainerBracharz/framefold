import Foundation
import UIKit

/// Montiert mehrere Werke zu einem durchlaufenden Ausstellungs-Reel:
/// vor jedem Werk eine Katalog-Titelkarte (Werktitel, Jahr), danach dessen
/// Bilder – alles zu einem Film im einheitlichen 9:16-Format.
enum ExhibitionBuilder {

    struct Work {
        let title: String
        let year: String
        let frames: [URL]
    }

    /// titleHold = Anzahl gehaltener Titelkarten-Bilder (bei 10 fps ≈ 1,2 s).
    static func build(
        works: [Work],
        settings: PipelineSettings,
        titleHold: Int = 12,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let cardSize = CGSize(width: 1080, height: 1920)
        var urls: [URL] = []
        for work in works {
            let card = titleCard(title: work.title, year: work.year, size: cardSize)
            if let cardURL = try? saveTemp(card) {
                for _ in 0..<max(1, titleHold) { urls.append(cardURL) }
            }
            urls.append(contentsOf: work.frames)
        }
        guard !urls.isEmpty else { throw PipelineError.noKeyframesFound }

        var s = settings
        s.aspect = .reel          // einheitlich 9:16
        s.loopMode = .none
        s.transitionFrames = 0
        s.interferenzEcho = false
        return try await StopMotionAssembler().assemble(
            imageURLs: urls, settings: s, progress: progress)
    }

    // MARK: Titelkarte

    private static func titleCard(title: String, year: String, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            // Galeriewand
            UIColor(red: 0.957, green: 0.953, blue: 0.945, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            let ink = UIColor(red: 0.067, green: 0.063, blue: 0.063, alpha: 1)
            let graphite = UIColor(red: 0.29, green: 0.28, blue: 0.26, alpha: 1)

            // Werktitel (Serif, zentriert)
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let titleAttr: [NSAttributedString.Key: Any] = [
                .font: serifFont(96, weight: .regular),
                .foregroundColor: ink, .paragraphStyle: para
            ]
            let titleRect = CGRect(x: 80, y: size.height/2 - 170, width: size.width - 160, height: 320)
            NSAttributedString(string: title, attributes: titleAttr).draw(in: titleRect)

            // Spektralbalken
            let bar = CGRect(x: size.width/2 - 90, y: size.height/2 + 150, width: 180, height: 8)
            let colors = [UIColor(red:0.42,green:0.36,blue:0.91,alpha:1).cgColor,
                          UIColor(red:0.13,green:0.83,blue:0.78,alpha:1).cgColor]
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors as CFArray, locations: [0,1]) {
                cg.saveGState(); cg.addRect(bar); cg.clip()
                cg.drawLinearGradient(grad, start: CGPoint(x: bar.minX, y: 0),
                                      end: CGPoint(x: bar.maxX, y: 0), options: [])
                cg.restoreGState()
            }

            // Jahr (Mono, gesperrt)
            let yearPara = NSMutableParagraphStyle(); yearPara.alignment = .center
            let yearAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 30, weight: .medium),
                .foregroundColor: graphite, .kern: 6, .paragraphStyle: yearPara
            ]
            NSAttributedString(string: year.uppercased(), attributes: yearAttr)
                .draw(in: CGRect(x: 80, y: size.height/2 + 190, width: size.width - 160, height: 60))
        }
    }

    private static func serifFont(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: d, size: size)
        }
        return base
    }

    private static func saveTemp(_ image: UIImage) throws -> URL {
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw PipelineError.exportFailed
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("titlecard-\(UUID().uuidString).jpg")
        try data.write(to: url)
        return url
    }
}
