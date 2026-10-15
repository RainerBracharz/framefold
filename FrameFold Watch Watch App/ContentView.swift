import SwiftUI
import Combine    // ObservableObject / @Published
import WatchConnectivity
import WatchKit   // WKInterfaceDevice: haptische Rückmeldung am Handgelenk

/// Fernauslöser am Handgelenk. Bewusst minimal: ein großer Auslöser, der
/// Bildzähler, der Zustand — und „Fertig". Das iPhone bleibt am Stativ,
/// niemand muss es berühren.
struct ContentView: View {
    @StateObject private var link = WatchShutter()

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                // Der Zustand ist die einzige Schrift – kein App-Name, kein
                // Werktitel: beides wüsste man ohnehin.
                Text(link.status.uppercased())
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.3)
                    .foregroundStyle(link.canShoot
                                     ? Theme.paperOnDark.opacity(0.7)
                                     : Theme.amber)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                // Der Auslöser: so groß wie das Zifferblatt hergibt
                Button {
                    link.shutter()
                } label: {
                    ZStack {
                        Circle().stroke(Theme.paperOnDark, lineWidth: 3)
                        Circle().fill(Theme.paperOnDark).padding(7)
                        Text("\(link.count)")
                            .font(.system(size: 30, weight: .regular, design: .serif))
                            .foregroundStyle(Theme.darkroom)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.2), value: link.count)
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 96, height: 96)
                .disabled(!link.canShoot)
                .opacity(link.canShoot ? 1 : 0.45)
                .accessibilityLabel("Auslöser")
                .accessibilityValue("\(link.count) Bilder")

                Button("Fertig") { link.finish() }
                    .font(.system(size: 13, weight: .medium))
                    .tint(Theme.amber)
                    .disabled(!link.canShoot)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.darkroom)
            // Kein Titel: Wer die App am Handgelenk öffnet, weiß, was sie tut.
            // Der Werkname stünde nur halb abgeschnitten neben der Uhrzeit.
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: Verbindung zum iPhone

/// Schickt Auslöse-Befehle ans iPhone und empfängt den Zählerstand zurück.
@MainActor
final class WatchShutter: NSObject, ObservableObject {
    @Published var count = 0
    @Published var status = String(localized: "Verbinde…")
    @Published var isConnected = false
    /// Läuft am iPhone gerade der Sucher? Nur dann löst der Knopf etwas aus.
    @Published var isActive = false
    var canShoot: Bool { isConnected && isActive }

    /// Nach dem Ende einer Aufnahme wieder auf Anfang.
    func reset() { count = 0 }

    private let session = WCSession.default

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    func shutter() {
        send(["command": "shutter"], success: .click)
    }

    func finish() {
        send(["command": "finish"], success: .success)
    }

    /// Haptik erst, wenn das iPhone bestätigt hat – eine verlorene Nachricht
    /// soll sich nicht wie ein Auslösen anfühlen.
    private func send(_ payload: [String: Any], success: WKHapticType) {
        guard session.isReachable else {
            status = String(localized: "iPhone nicht erreichbar")
            WKInterfaceDevice.current().play(.failure)
            return
        }
        session.sendMessage(payload, replyHandler: { reply in
            let ok = reply["ok"] as? Bool ?? false
            Task { @MainActor in
                WKInterfaceDevice.current().play(ok ? success : .failure)
                if !ok { self.status = String(localized: "Kamera-Tab am iPhone öffnen") }
            }
        }, errorHandler: { _ in
            Task { @MainActor in
                WKInterfaceDevice.current().play(.failure)
                self.status = String(localized: "Nicht ausgelöst – iPhone prüfen")
            }
        })
    }

    /// Stand vom iPhone übernehmen (Nachricht oder Application Context).
    fileprivate func apply(_ message: [String: Any]) {
        if let c = message["count"] as? Int { count = c }
        if let s = message["status"] as? String { status = s }
        if let a = message["active"] as? Bool { isActive = a }
        if message["reset"] as? Bool == true { reset() }
    }
}

extension WatchShutter: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in
            self.isConnected = session.isReachable
            self.apply(context)
            if !session.isReachable { self.status = String(localized: "FrameFold am iPhone öffnen") }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isConnected = session.isReachable
            if !session.isReachable { self.status = String(localized: "FrameFold am iPhone öffnen") }
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.apply(message) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }
}

// MARK: Farben (kleine Fassung des Designsystems)

private enum Theme {
    static let darkroom = Color(red: 0.078, green: 0.071, blue: 0.059)
    static let paperOnDark = Color(red: 0.922, green: 0.894, blue: 0.839)
    static let amber = Color(red: 0.949, green: 0.796, blue: 0.420)
}

#Preview {
    ContentView()
}
