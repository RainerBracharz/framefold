import CoreBluetooth
import Foundation

/// Position aller Achsen (in Motorschritten) ab einem Bild.
struct MotionKey: Codable, Equatable, Identifiable {
    var id = UUID()
    var frame: Int
    var positions: [Int]
}

/// Das Textprotokoll zum Motorsteuergerät – bewusst einfach, damit es auf
/// jedem ESP32/Arduino mit Bluetooth läuft (Nordic UART Service). Jede
/// Zeile endet mit „\n“. Beschrieben in docs/motion/README.md.
enum MotionProtocol {
    static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rx = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")   // App → Gerät
    static let tx = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")   // Gerät → App

    enum Reply: Equatable {
        case hello(axes: Int)
        case arrived(axis: Int)
        case positions([Int])
        case error(String)
    }

    static func hello() -> String { "hi\n" }
    static func move(axis: Int, to position: Int) -> String { "mm \(axis) \(position)\n" }
    static func setZero() -> String { "zm\n" }
    static func report() -> String { "pr\n" }

    static func parse(_ line: String) -> Reply? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard let head = parts.first else { return nil }
        switch head {
        case "hi": return parts.count > 1 ? Int(parts[1]).map { .hello(axes: max(1, min(8, $0))) } : .hello(axes: 1)
        case "ok": return parts.count > 1 ? Int(parts[1]).map { .arrived(axis: $0) } : nil
        case "pr": return .positions(parts.dropFirst().compactMap { Int($0) })
        case "er": return .error(parts.dropFirst().joined(separator: " "))
        default: return nil
        }
    }

    /// Positionen für ein Bild: zwischen den Schlüsseln gleichförmig oder
    /// weich; vor dem ersten und nach dem letzten Schlüssel bleibt es stehen.
    static func positions(_ keys: [MotionKey], at frame: Int, axes: Int, smooth: Bool) -> [Int] {
        let sorted = keys.sorted { $0.frame < $1.frame }
        func padded(_ key: MotionKey?) -> [Double] {
            (0..<axes).map { i in Double(key.flatMap { i < $0.positions.count ? $0.positions[i] : nil } ?? 0) }
        }
        guard let first = sorted.first else { return [Int](repeating: 0, count: axes) }
        guard let before = sorted.last(where: { $0.frame <= frame }) else { return padded(first).map { Int($0) } }
        guard let after = sorted.first(where: { $0.frame > frame }) else { return padded(before).map { Int($0) } }
        var t = Double(frame - before.frame) / Double(after.frame - before.frame)
        if smooth { t = t * t * (3 - 2 * t) }
        return zip(padded(before), padded(after)).map { Int(($0 + ($1 - $0) * t).rounded()) }
    }
}

/// Verbindung zum Motorsteuergerät per Bluetooth. Nur aktiv, wenn im
/// Studio eingeschaltet.
@MainActor
final class MotionController: NSObject, ObservableObject {
    struct Device: Identifiable, Equatable { let id: UUID; let name: String }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var connectedName: String?
    @Published private(set) var axes = 1
    @Published private(set) var positions: [Int] = [0]
    @Published private(set) var isMoving = false
    @Published private(set) var isScanning = false
    @Published var lastError: String?

    private var central: CBCentralManager?
    private var found: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var buffer = ""
    private var waiting: Set<Int> = []
    private var moveContinuation: CheckedContinuation<Bool, Never>?

    var isConnected: Bool { rx != nil }

    func scan() {
        lastError = nil
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else if central?.state == .poweredOn {
            startScan()
        }
    }

    private func startScan() {
        isScanning = true
        central?.scanForPeripherals(withServices: [MotionProtocol.service])
    }

    func connect(_ device: Device) {
        guard let p = found[device.id] else { return }
        central?.stopScan()
        isScanning = false
        peripheral = p
        p.delegate = self
        central?.connect(p)
    }

    func disconnect() {
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        rx = nil
        connectedName = nil
        isScanning = false
        finishMove(false)
    }

    /// Alle Achsen an die Positionen fahren und warten, bis das Gerät die
    /// Ankunft meldet (höchstens `timeout` Sekunden).
    func move(to target: [Int], timeout: Double = 60) async -> Bool {
        guard isConnected else { return false }
        finishMove(false)
        let axesToMove = (0..<min(axes, target.count)).filter { target[$0] != positions[safe: $0] }
        guard !axesToMove.isEmpty else { return true }
        isMoving = true
        waiting = Set(axesToMove.map { $0 + 1 })
        for i in axesToMove { send(MotionProtocol.move(axis: i + 1, to: target[i])) }
        let ok = await withCheckedContinuation { continuation in
            moveContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if self?.moveContinuation != nil {
                    self?.lastError = String(localized: "Das Motorsteuergerät hat die Ankunft nicht gemeldet.")
                    self?.finishMove(false)
                }
            }
        }
        if ok { for i in axesToMove where i < positions.count { positions[i] = target[i] } }
        return ok
    }

    func jog(axis: Int, by steps: Int) {
        var target = positions
        guard target.indices.contains(axis) else { return }
        target[axis] += steps
        Task { _ = await move(to: target) }
    }

    func setZero() {
        send(MotionProtocol.setZero())
        positions = [Int](repeating: 0, count: axes)
    }

    private func finishMove(_ ok: Bool) {
        isMoving = false
        waiting = []
        moveContinuation?.resume(returning: ok)
        moveContinuation = nil
    }

    private func send(_ line: String) {
        guard let peripheral, let rx else { return }
        let type: CBCharacteristicWriteType = rx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(Data(line.utf8), for: rx, type: type)
    }

    fileprivate func received(_ data: Data) {
        buffer += String(decoding: data, as: UTF8.self)
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            switch MotionProtocol.parse(line) {
            case .hello(let n):
                axes = n
                positions = [Int](repeating: 0, count: n)
                send(MotionProtocol.report())
            case .positions(let p):
                positions = (0..<axes).map { $0 < p.count ? p[$0] : 0 }
            case .arrived(let axis):
                waiting.remove(axis)
                if waiting.isEmpty, moveContinuation != nil { finishMove(true) }
            case .error(let message):
                lastError = message
                finishMove(false)
            case nil:
                break
            }
        }
        if buffer.count > 4096 { buffer = "" }
    }

    fileprivate func ready(_ characteristic: CBCharacteristic, name: String?) {
        rx = characteristic
        connectedName = name ?? String(localized: "Motorsteuerung")
        send(MotionProtocol.hello())
    }
}

extension MotionController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state == .poweredOn { startScan() }
            else if central.state == .unauthorized {
                lastError = String(localized: "Kein Bluetooth-Zugriff – in den Einstellungen erlauben.")
            } else if central.state == .poweredOff {
                lastError = String(localized: "Bluetooth ist ausgeschaltet.")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            found[peripheral.identifier] = peripheral
            let device = Device(id: peripheral.identifier, name: peripheral.name ?? String(localized: "Motorsteuerung"))
            if !devices.contains(device) { devices.append(device) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([MotionProtocol.service])
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { lastError = error?.localizedDescription }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            rx = nil
            connectedName = nil
            finishMove(false)
        }
    }
}

extension MotionController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == MotionProtocol.service }) else { return }
        peripheral.discoverCharacteristics([MotionProtocol.rx, MotionProtocol.tx], for: service)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        if let tx = chars.first(where: { $0.uuid == MotionProtocol.tx }) { peripheral.setNotifyValue(true, for: tx) }
        if let rx = chars.first(where: { $0.uuid == MotionProtocol.rx }) {
            let name = peripheral.name
            MainActor.assumeIsolated { ready(rx, name: name) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        MainActor.assumeIsolated { received(data) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
