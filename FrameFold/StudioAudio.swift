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
    /// Hörbare Spuren mit Einsatz in Sekunden bei `fps`. Gekürzte oder
    /// bearbeitete Spuren kommen aus dem Zwischenspeicher; ist die Fassung
    /// noch nicht gerechnet, wird sie im Hintergrund bestellt und bis dahin
    /// das Original gespielt. Für den Export `renderedAudioSources` nehmen.
    @MainActor
    func audioSources(fps: Int32, store: ProjectStore) -> [AudioSource] {
        allAudioTracks.filter { !$0.muted }.map { track in
            let original = store.url(for: track, in: self)
            var url = original
            if let spec = ShapeSpec(track: track, source: original) {
                let shaped = AudioShaper.target(for: spec)
                if FileManager.default.fileExists(atPath: shaped.path) { url = shaped }
                else { AudioShapeCenter.shared.request(spec) }
            }
            return AudioSource(url: url, start: Double(min(max(0, track.startFrame), 100_000)) / Double(max(1, fps)), volume: track.volume)
        }
    }

    /// Wie `audioSources`, aber wartet, bis alle bearbeiteten Spuren
    /// gerechnet sind – im Hintergrund.
    @MainActor
    func renderedAudioSources(fps: Int32, store: ProjectStore) async -> [AudioSource] {
        let jobs: [(ShapeSpec?, AudioSource)] = allAudioTracks.filter { !$0.muted }.map { track in
            let original = store.url(for: track, in: self)
            return (ShapeSpec(track: track, source: original),
                    AudioSource(url: original, start: Double(min(max(0, track.startFrame), 100_000)) / Double(max(1, fps)), volume: track.volume))
        }
        return await Task.detached(priority: .userInitiated) {
            jobs.map { spec, source in
                guard let spec else { return source }
                var shaped = source
                if let url = try? AudioShaper.render(spec) { shaped.url = url }
                return shaped
            }
        }.value
    }
}

// MARK: Kürzen, Blenden, Effekt

/// Was mit einer Spur geschehen soll – nil, wenn sie unverändert bleibt.
struct ShapeSpec: Sendable, Hashable {
    let trackID: UUID
    let source: URL
    let trim: Double, length: Double, fadeIn: Double, fadeOut: Double
    let effect: VoiceEffect?

    init?(track: AudioTrack, source: URL) {
        guard track.isShaped else { return nil }
        trackID = track.id
        self.source = source
        trim = Self.seconds(track.trimStart)
        length = Self.seconds(track.maxLength)
        fadeIn = Self.seconds(track.fadeIn)
        fadeOut = Self.seconds(track.fadeOut)
        effect = track.voiceEffect
    }

    /// Endliche Sekunden zwischen 0 und einer Stunde – Werte aus fremden
    /// Werken dürfen die Umrechnung in Samples nicht sprengen.
    private static func seconds(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return min(max(0, value), 3600)
    }
}

/// Bestellt bearbeitete Fassungen im Hintergrund – gebündelt, damit
/// schnelles Klicken am Regler nicht jede Zwischenstufe rechnet – und
/// meldet über `revision`, wenn eine fertig ist.
@MainActor
final class AudioShapeCenter: ObservableObject {
    static let shared = AudioShapeCenter()
    @Published private(set) var revision = 0
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var wanted: [UUID: ShapeSpec] = [:]

    func request(_ spec: ShapeSpec) {
        guard wanted[spec.trackID] != spec else { return }
        wanted[spec.trackID] = spec
        pending[spec.trackID]?.cancel()
        pending[spec.trackID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            _ = await Task.detached(priority: .utility) { try? AudioShaper.render(spec) }.value
            guard let self, !Task.isCancelled else { return }
            self.pending[spec.trackID] = nil
            self.wanted[spec.trackID] = nil
            self.revision += 1
        }
    }
}

/// Gekürzte, geblendete oder verfremdete Fassung einer Spur als eigene
/// Datei. Mischung, Wellenform und Wiedergabe im Studio nehmen dann einfach
/// diese Datei – so klingen alle drei gleich. Gerechnet wird in Stücken,
/// damit auch lange Musik nicht den Speicher füllt.
enum AudioShaper {
    static func target(for spec: ShapeSpec) -> URL {
        let modified = (try? spec.source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let key = "\(spec.source.path)|\(modified)|\(spec.trim)|\(spec.length)|\(spec.fadeIn)|\(spec.fadeOut)|\(spec.effect?.rawValue ?? "")"
        let hash = key.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-clip-\(spec.trackID.uuidString)-\(String(hash, radix: 16)).caf")
    }

    static func render(_ spec: ShapeSpec) throws -> URL {
        let target = target(for: spec)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { return target }

        let file = try AVAudioFile(forReading: spec.source)
        let format = file.processingFormat
        let rate = format.sampleRate
        let first = min(file.length, AVAudioFramePosition(spec.trim * rate))
        var count = file.length - first
        if spec.length > 0 { count = min(count, AVAudioFramePosition(spec.length * rate)) }

        let partial = fm.temporaryDirectory.appendingPathComponent("ff-clip-teil-\(UUID().uuidString).caf")
        defer { try? fm.removeItem(at: partial) }
        do {
            let out = try AVAudioFile(forWriting: partial, settings: format.settings)
            if count > 0 {
                try stream(file, from: first, count: count, spec: spec, into: out)
            } else if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate / 20)) {
                // Alles weggekürzt: kurze Stille statt der ungekürzten Spur
                silence.frameLength = silence.frameCapacity
                for c in 0..<Int(format.channelCount) { silence.floatChannelData?[c].update(repeating: 0, count: Int(silence.frameLength)) }
                try out.write(from: silence)
            }
            if #available(iOS 18.0, macCatalyst 18.0, *) { out.close() }
        }
        // Ältere Fassungen derselben Spur wegräumen – jede Reglerstellung
        // wäre sonst eine eigene, große Datei
        let prefix = "ff-clip-\(spec.trackID.uuidString)-"
        for name in (try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? [] where name.hasPrefix(prefix) {
            try? fm.removeItem(at: fm.temporaryDirectory.appendingPathComponent(name))
        }
        if !fm.fileExists(atPath: target.path) { try fm.moveItem(at: partial, to: target) }
        return target
    }

    /// Stück für Stück lesen (oder durch die Tonhöhen-Einheit rechnen),
    /// Effekt und Blenden anwenden, schreiben.
    private static func stream(_ file: AVAudioFile, from first: AVAudioFramePosition, count: AVAudioFramePosition,
                               spec: ShapeSpec, into out: AVAudioFile) throws {
        let format = file.processingFormat
        let rate = format.sampleRate
        let chunkSize: AVAudioFrameCount = 16_384
        let inFrames = AVAudioFramePosition(spec.fadeIn * rate), outFrames = AVAudioFramePosition(spec.fadeOut * rate)

        var engine: AVAudioEngine?
        if let effect = spec.effect, effect != .robot {
            let e = AVAudioEngine(), player = AVAudioPlayerNode(), pitch = AVAudioUnitTimePitch()
            pitch.pitch = effect == .high ? 700 : -600   // Cent
            e.attach(player); e.attach(pitch)
            e.connect(player, to: pitch, format: format)
            e.connect(pitch, to: e.mainMixerNode, format: format)
            try e.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunkSize)
            try e.start()
            player.scheduleSegment(file, startingFrame: first, frameCount: AVAudioFrameCount(count), at: nil)
            player.play()
            engine = e
        } else {
            file.framePosition = first
        }
        defer { engine?.stop() }
        guard let chunk = AVAudioPCMBuffer(pcmFormat: engine?.manualRenderingFormat ?? format, frameCapacity: chunkSize)
        else { throw PipelineError.exportFailed }

        var done: AVAudioFramePosition = 0
        while done < count {
            let wanted = AVAudioFrameCount(min(AVAudioFramePosition(chunkSize), count - done))
            if let engine {
                guard try engine.renderOffline(wanted, to: chunk) == .success else { break }
            } else {
                try file.read(into: chunk, frameCount: wanted)
            }
            let n = Int(chunk.frameLength)
            guard n > 0, let channels = chunk.floatChannelData else { break }
            for c in 0..<Int(chunk.format.channelCount) {
                let data = channels[c]
                for i in 0..<n {
                    let position = done + AVAudioFramePosition(i)
                    var gain: Float = 1
                    if position < inFrames { gain *= Float(position) / Float(inFrames) }
                    let fromEnd = count - 1 - position
                    if fromEnd < outFrames { gain *= Float(fromEnd) / Float(outFrames) }
                    var v = data[i]
                    if spec.effect == .robot {
                        // Ringmodulation: die Stimme klingt nach Blech und Strom
                        let carrier = Float(sin(2 * Double.pi * 55 * Double(position) / rate))
                        v = v * carrier * 0.8 + v * 0.35
                    }
                    data[i] = v * gain
                }
            }
            try out.write(from: chunk)
            done += AVAudioFramePosition(n)
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
        // Beim Anspielen eines Bilds die Engine danach wieder schlafen legen
        if let duration {
            pauseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((duration + 0.15) * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if self.engine.isRunning { self.engine.pause() }
            }
        }
    }

    func stop() {
        pauseTask?.cancel()
        for (node, _, _) in nodes { node.stop() }
        // Engine anhalten: sonst bliebe die Audio-Hardware nach dem ersten
        // Abspielen dauerhaft wach und kostete Akku
        if engine.isRunning { engine.pause() }
    }

    private var pauseTask: Task<Void, Never>?
}
