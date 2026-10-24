import AVFoundation
import Foundation

/// Eine Spur, so wie sie in Mischung und Wiedergabe eingeht.
struct AudioSource: Equatable {
    var url: URL
    /// Einsatz in Sekunden ab Filmbeginn
    var start: Double
    var volume: Double
}

extension Project {
    /// Hörbare Spuren mit Einsatz in Sekunden bei `fps`.
    @MainActor
    func audioSources(fps: Int32, store: ProjectStore) -> [AudioSource] {
        allAudioTracks.filter { !$0.muted }.map {
            AudioSource(url: store.url(for: $0, in: self),
                        start: Double($0.startFrame) / Double(max(1, fps)),
                        volume: $0.volume)
        }
    }
}

// MARK: Mischung

enum AudioMixer {
    static let sampleRate = 48_000.0

    /// Mischt alle Spuren zu einer AAC-Datei der Länge `duration` –
    /// offline, schneller als Echtzeit. Spuren, die über das Ende reichen,
    /// werden abgeschnitten.
    static func mix(_ sources: [AudioSource], duration: Double) throws -> URL {
        guard !sources.isEmpty, duration > 0 else { throw PipelineError.exportFailed }
        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw PipelineError.exportFailed
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)

        var scheduled: [(AVAudioPlayerNode, AVAudioFile, AVAudioFramePosition)] = []
        for source in sources {
            guard let file = try? AVAudioFile(forReading: source.url) else { continue }
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            player.volume = Float(source.volume)
            scheduled.append((player, file, AVAudioFramePosition(source.start * file.processingFormat.sampleRate)))
        }
        guard !scheduled.isEmpty else { throw PipelineError.exportFailed }
        try engine.start()
        for (player, file, startSample) in scheduled {
            player.scheduleFile(file, at: AVAudioTime(sampleTime: startSample, atRate: file.processingFormat.sampleRate))
            player.play()
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("framefold-mix-\(UUID().uuidString.prefix(8)).m4a")
        let output = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw PipelineError.exportFailed
        }
        let total = AVAudioFramePosition(duration * sampleRate)
        while engine.manualRenderingSampleTime < total {
            let remaining = total - engine.manualRenderingSampleTime
            let count = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), remaining))
            let status = try engine.renderOffline(count, to: buffer)
            guard status == .success else { break }
            try output.write(from: buffer)
        }
        engine.stop()
        return url
    }
}

// MARK: Wellenform

enum Waveform {
    /// Spitzenwerte je Zeitfenster (`perSecond` Werte pro Sekunde), 0…1.
    static func peaks(of url: URL, perSecond: Int = 120) -> [Float] {
        if let cached = cacheLock.withLock({ cache[url] }) { return cached }
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let binSize = max(1, AVAudioFrameCount(format.sampleRate) / AVAudioFrameCount(perSecond))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: binSize * 256) else { return [] }
        var peaks: [Float] = []
        peaks.reserveCapacity(Int(Double(file.length) / format.sampleRate * Double(perSecond)) + 1)
        while file.framePosition < file.length {
            guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0,
                  let channels = buffer.floatChannelData else { break }
            let length = Int(buffer.frameLength)
            var start = 0
            while start < length {
                let end = min(length, start + Int(binSize))
                var peak: Float = 0
                for c in 0..<Int(format.channelCount) {
                    let data = channels[c]
                    for i in start..<end { peak = max(peak, abs(data[i])) }
                }
                peaks.append(min(1, peak))
                start = end
            }
        }
        cacheLock.withLock { cache[url] = peaks }
        return peaks
    }

    /// Spuren auf die Film-Zeitachse legen: Einsatz verschieben, Lautstärke
    /// anwenden, Maximum bilden.
    static func combined(_ sources: [AudioSource], perSecond: Int = 120) -> [Float] {
        var result: [Float] = []
        for source in sources {
            let peaks = Self.peaks(of: source.url, perSecond: perSecond)
            let offset = Int((source.start * Double(perSecond)).rounded())
            if result.count < offset + peaks.count {
                result += [Float](repeating: 0, count: offset + peaks.count - result.count)
            }
            for (i, value) in peaks.enumerated() {
                result[offset + i] = max(result[offset + i], min(1, value * Float(source.volume)))
            }
        }
        return result
    }

    /// Mehrere Hintergrund-Aufgaben lesen gleichzeitig – ohne Sperre würde
    /// das Wörterbuch beim gleichzeitigen Schreiben beschädigt.
    nonisolated(unsafe) private static var cache: [URL: [Float]] = [:]
    private static let cacheLock = NSLock()
}

// MARK: Wiedergabe im Studio

/// Spielt die Spuren synchron zum Abspielen der Bilder – und beim Blättern
/// den Ton genau eines Bilds („Scrubbing“), wie im Dragonframe-Arbeitsfluss.
@MainActor
final class StudioAudioPlayer {
    private let engine = AVAudioEngine()
    private var nodes: [(AVAudioPlayerNode, AVAudioFile, AudioSource)] = []
    private var loaded: [AudioSource] = []

    func load(_ sources: [AudioSource]) {
        guard sources != loaded else { return }
        stop()
        for (node, _, _) in nodes { engine.detach(node) }
        nodes = []
        loaded = sources
        for source in sources {
            guard let file = try? AVAudioFile(forReading: source.url) else { continue }
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            node.volume = Float(source.volume)
            nodes.append((node, file, source))
        }
    }

    /// Ab Sekunde `time` spielen; mit `duration` nur so lange (Scrubbing).
    func play(from time: Double, duration: Double? = nil) {
        stop()
        guard !nodes.isEmpty else { return }
        if !engine.isRunning { try? engine.start() }
        for (node, file, source) in nodes {
            let rate = file.processingFormat.sampleRate
            let into = time - source.start          // Position in der Datei
            var startFrame = AVAudioFramePosition(max(0, into) * rate)
            let delay = max(0, -into)                // Spur setzt erst später ein
            guard startFrame < file.length else { continue }
            var count = file.length - startFrame
            if let duration {
                let wanted = AVAudioFramePosition(max(0, duration - delay) * rate)
                guard wanted > 0 else { continue }
                count = min(count, wanted)
            }
            startFrame = max(0, startFrame)
            node.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(count),
                                 at: delay > 0 ? AVAudioTime(sampleTime: AVAudioFramePosition(delay * rate), atRate: rate) : nil)
            node.play()
        }
    }

    func stop() {
        for (node, _, _) in nodes { node.stop() }
    }
}
