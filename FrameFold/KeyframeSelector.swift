import Foundation

/// Findet "Ruhefenster" (zusammenhängende Bereiche geringer Bewegung)
/// und wählt pro Fenster den besten Frame.
struct KeyframeSelector {

    struct StillWindow {
        let frames: [FrameAnalyzer.AnalyzedFrame]
        var startSeconds: Double { frames.first?.seconds ?? 0 }
        var endSeconds: Double { frames.last?.seconds ?? 0 }
    }

    /// Zerlegt die Frame-Folge in Ruhefenster.
    /// Schwelle: Otsu-Split mit Perzentil-Untergrenze (siehe Algorithms) –
    /// verifiziert gegen die Python-Referenz und die Linux-Swift-Tests.
    static func stillWindows(
        frames: [FrameAnalyzer.AnalyzedFrame],
        settings: PipelineSettings
    ) -> [StillWindow] {
        guard frames.count > 1 else { return [] }
        let analyzed = Array(frames.dropFirst()) // ersten Frame (motion=0) ignorieren
        let scores = analyzed.map(\.motionScore)
        let threshold = Algorithms.motionThreshold(
            scores: scores, percentile: settings.motionPercentile)
        let minFrames = max(1, Int(settings.minStillWindowSeconds * settings.samplingFPS))

        return Algorithms.stillWindowRanges(
            motionScores: scores, threshold: threshold, minFrames: minFrames
        ).map { range in
            StillWindow(frames: Array(analyzed[range]))
        }
    }

    /// Wählt pro Fenster die Frames sortiert nach Schärfe (bester zuerst).
    /// Die Handprüfung läuft später über diese Rangliste: fällt der beste
    /// Frame wegen Händen durch, kommt der nächstbeste dran.
    static func rankedCandidates(in window: StillWindow) -> [FrameAnalyzer.AnalyzedFrame] {
        window.frames
            .map { frame -> (FrameAnalyzer.AnalyzedFrame, Double) in
                let sharpness = FrameAnalyzer.laplacianVariance(
                    gray: frame.grayPixels, width: frame.width, height: frame.height)
                return (frame, sharpness)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}
