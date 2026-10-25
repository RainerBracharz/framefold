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
        allAudioTracks.filter { !$0.muted }.map { track in
            let original = store.url(for: track, in: self)
            return AudioSource(url: track.isShaped ? ((try? AudioShaper.shaped(original, track: track)) ?? original) : original,
                               start: Double(track.startFrame) / Double(max(1, fps)),
                               volume: track.volume)
        }
    }
}

// MARK: Kürzen und Blenden

/// Gekürzte und geblendete Fassung einer Spur als eigene Datei. Mischung,
/// Wellenform und Wiedergabe im Studio nehmen dann einfach diese Datei –
/// so klingen alle drei gleich.
enum AudioShaper {
    static func shaped(_ source: URL, track: AudioTrack) throws -> URL {
        let trim = max(0, track.trimStart ?? 0), length = max(0, track.maxLength ?? 0)
        let fadeIn = max(0, track.fadeIn ?? 0), fadeOut = max(0, track.fadeOut ?? 0)
        let modified = (try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let key = "\(source.path)|\(modified)|\(trim)|\(length)|\(fadeIn)|\(fadeOut)"
        let hash = key.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("ff-clip-\(String(hash, radix: 16)).caf")
        if FileManager.default.fileExists(atPath: target.path) { return target }

        let file = try AVAudioFile(forReading: source)
        let format = file.processingFormat
        let rate = format.sampleRate
        let first = min(file.length, AVAudioFramePosition(trim * rate))
        var count = file.length - first
        if length > 0 { count = min(count, AVAudioFramePosition(length * rate)) }
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { throw PipelineError.exportFailed }
        file.framePosition = first
        // AVAudioFile liest je Aufruf nicht immer alles – in Stücken anhängen
        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { throw PipelineError.exportFailed }
        while buffer.frameLength < AVAudioFrameCount(count) {
            let wanted = min(chunk.frameCapacity, AVAudioFrameCount(count) - buffer.frameLength)
            try file.read(into: chunk, frameCount: wanted)
            guard chunk.frameLength > 0, let src = chunk.floatChannelData else { break }
            for c in 0..<Int(format.channelCount) {
                (channels[c] + Int(buffer.frameLength)).update(from: src[c], count: Int(chunk.frameLength))
            }
            buffer.frameLength += chunk.frameLength
        }
        let frames = Int(buffer.frameLength)
        let inFrames = min(frames, Int(fadeIn * rate)), outFrames = min(frames, Int(fadeOut * rate))
        for c in 0..<Int(format.channelCount) {
            let data = channels[c]
            for i in 0..<inFrames { data[i] *= Float(i) / Float(inFrames) }
            for i in 0..<outFrames { data[frames - 1 - i] *= Float(i) / Float(outFrames) }
        }
        let partial = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent)")
        try? FileManager.default.removeItem(at: partial)
        do {
            let out = try AVAudioFile(forWriting: partial, settings: format.settings)
            try out.write(from: buffer)
            // Erst geschlossen ist die Datei vollständig auf der Platte
            if #available(iOS 18.0, macCatalyst 18.0, *) { out.close() }
        }
        try FileManager.default.moveItem(at: partial, to: target)
        return target
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
