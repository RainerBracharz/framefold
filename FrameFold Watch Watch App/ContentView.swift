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
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1.3)
                    .foregroundStyle(link.isConnected
                                     ? Theme.paperOnDark.opacity(0.55)
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
                .disabled(!link.isConnected)
                .opacity(link.isConnected ? 1 : 0.45)
                .accessibilityLabel("Auslöser")
                .accessibilityValue("\(link.count) Bilder")

                Button("Fertig") { link.finish() }
                    .font(.system(size: 12, weight: .medium))
                    .tint(Theme.amber)
                    .disabled(!link.isConnected)
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
    @Published var status = "Verbinde…"
    @Published var isConnected = false

    /// Nach dem Ende einer Aufnahme wieder auf Anfang.
    func reset() { count = 0; status = "Bereit" }

    private let session = WCSession.default

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    func shutter() {
        send(["command": "shutter"])
        // Sofortige Rückmeldung am Handgelenk – die Bestätigung vom iPhone
        // kommt Sekundenbruchteile später und korrigiert notfalls.
        WKInterfaceDevice.current().play(.click)
    }

    func finish() {
        send(["command": "finish"])
        WKInterfaceDevice.current().play(.success)
    }

    private func send(_ payload: [String: Any]) {
        guard session.isReachable else {
            status = "iPhone nicht erreichbar"
            return
        }
        session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
    }
}

extension WatchShutter: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.isConnected = session.isReachable
            self.status = session.isReachable ? "Bereit" : "Kamera-Tab öffnen"
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isConnected = session.isReachable
            self.status = session.isReachable ? "Bereit" : "Kamera-Tab öffnen"
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            if let c = message["count"] as? Int { self.count = c }
            if let s = message["status"] as? String { self.status = s }
            if message["reset"] as? Bool == true { self.reset() }
        }
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
