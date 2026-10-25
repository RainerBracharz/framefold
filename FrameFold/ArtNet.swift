import Foundation
import Network

/// Lichtstimmung ab einem Bild: Werte 0…255 je DMX-Kanal (Kanal 1 zuerst).
struct LightCue: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Ab diesem Bild (0-basiert) gilt die Stimmung
    var frame: Int
    var values: [Int]
}

/// Art-Net (DMX über das lokale Netz) – so steuern Studios ihr Licht Bild
/// für Bild: Ein Art-Net-Knoten oder ein Lichtpult setzt die Werte in DMX um.
enum ArtNet {
    static let port: UInt16 = 6454

    /// ArtDMX-Paket (OpCode 0x5000, Protokoll 14) für ein Universum.
    static func dmxPacket(universe: Int, sequence: UInt8, values: [UInt8]) -> Data {
        var data = Data("Art-Net".utf8)
        data.append(0)
        data.append(contentsOf: [0x00, 0x50])                 // OpCode, Little Endian
        data.append(contentsOf: [0x00, 14])                   // Protokollversion, Big Endian
        data.append(sequence)
        data.append(0)                                        // Physical
        let u = max(0, min(32767, universe))
        data.append(UInt8(u & 0xFF))                          // SubUni
        data.append(UInt8((u >> 8) & 0x7F))                   // Net
        // Länge gerade und 2…512
        var payload = Array(values.prefix(512))
        if payload.count < 2 { payload += [UInt8](repeating: 0, count: 2 - payload.count) }
        if payload.count % 2 == 1 { payload.append(0) }
        data.append(UInt8(payload.count >> 8))
        data.append(UInt8(payload.count & 0xFF))
        data.append(contentsOf: payload)
        return data
    }

    /// Werte für ein Bild: die letzte Stimmung an oder vor dem Bild; mit
    /// `fade` gleitend zur nächsten.
    static func values(_ cues: [LightCue], at frame: Int, channels: Int, fade: Bool) -> [UInt8] {
        let sorted = cues.sorted { $0.frame < $1.frame }
        func padded(_ cue: LightCue?) -> [Double] {
            (0..<channels).map { i in Double(cue.flatMap { i < $0.values.count ? $0.values[i] : nil } ?? 0) }
        }
        let before = sorted.last { $0.frame <= frame }
        var result = padded(before ?? sorted.first)
        if fade, let before, let after = sorted.first(where: { $0.frame > frame }) {
            let t = Double(frame - before.frame) / Double(after.frame - before.frame)
            let next = padded(after)
            result = zip(result, next).map { $0 + ($1 - $0) * t }
        }
        return result.map { UInt8(max(0, min(255, $0.rounded()))) }
    }
}

/// Schickt DMX-Werte an einen Art-Net-Knoten im lokalen Netz. Nur, wenn im
/// Studio eingeschaltet – sonst baut FrameFold keine Verbindung auf.
@MainActor
final class LightController: ObservableObject {
    @Published var enabled: Bool { didSet { save(); if !enabled { disconnect() } } }
    @Published var host: String { didSet { save(); disconnect() } }
    @Published var universe: Int { didSet { save() } }
    @Published var channels: Int { didSet { save() } }
    @Published private(set) var lastError: String?
    @Published private(set) var lastSent: [UInt8] = []

    private var connection: NWConnection?
    private var sequence: UInt8 = 1
    private let defaults = StudioDefaults.store

    init() {
        enabled = defaults.bool(forKey: "dmxEnabled")
        host = defaults.string(forKey: "dmxHost") ?? ""
        universe = defaults.integer(forKey: "dmxUniverse")
        let stored = defaults.integer(forKey: "dmxChannels")
        channels = stored > 0 ? min(stored, 32) : 4
    }

    private func save() {
        defaults.set(enabled, forKey: "dmxEnabled")
        defaults.set(host, forKey: "dmxHost")
        defaults.set(universe, forKey: "dmxUniverse")
        defaults.set(channels, forKey: "dmxChannels")
    }

    func send(_ values: [UInt8]) {
        guard enabled else { return }
        let target = host.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, let port = NWEndpoint.Port(rawValue: ArtNet.port) else {
            lastError = String(localized: "Adresse des Art-Net-Knotens fehlt.")
            return
        }
        if connection == nil {
            let parameters = NWParameters.udp
            // Nie über Mobilfunk oder ins Internet – nur das lokale Netz
            parameters.prohibitedInterfaceTypes = [.cellular]
            let c = NWConnection(host: NWEndpoint.Host(target), port: port, using: parameters)
            c.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    Task { @MainActor in self?.lastError = error.localizedDescription; self?.disconnect() }
                }
            }
            c.start(queue: .global(qos: .userInitiated))
            connection = c
        }
        let packet = ArtNet.dmxPacket(universe: universe, sequence: sequence, values: values)
        sequence = sequence == 255 ? 1 : sequence + 1
        connection?.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error { Task { @MainActor in self?.lastError = error.localizedDescription } }
        })
        lastSent = values
        lastError = nil
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }
}
