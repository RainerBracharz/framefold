import Foundation
import WatchConnectivity

/// Fernauslöser am Handgelenk: Die Watch schickt „auslösen", das iPhone
/// antwortet mit dem Zählerstand. Steht das iPhone am Stativ, muss niemand
/// mehr das Stativ berühren.
///
/// Bewusst schlank gehalten: keine Bildübertragung (das Wackeln zu vermeiden
/// ist der Zweck, nicht ein zweiter Sucher), nur Auslösen und Zählen.
@MainActor
final class WatchLink: NSObject, ObservableObject {
    static let shared = WatchLink()

    /// Wird gerufen, wenn die Watch auslöst – setzt der Sucher.
    var onShutter: (() -> Void)?
    /// Wird gerufen, wenn die Watch die Session beenden will.
    var onFinish: (() -> Void)?

    /// Ist eine Watch in Reichweite und die App dort installiert?
    @Published private(set) var isReachable = false

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Letzter Stand – wird beim Wiederverbinden erneut geschickt und liegt
    /// als Application Context bereit, falls die Watch-App erst später öffnet.
    private var lastPayload: [String: Any] = ["active": false, "count": 0]

    /// Session beendet – die Uhr zurücksetzen, statt den letzten Stand
    /// stehenzulassen. `active: false` sagt der Watch, dass ihr Auslöser
    /// gerade ins Leere ginge.
    func pushSessionEnded() {
        send(["reset": true, "active": false, "count": 0,
              "status": String(localized: "Kamera-Tab am iPhone öffnen")])
    }

    /// Zählerstand und Werkname ans Handgelenk melden – nur, solange der
    /// Sucher läuft (`active`).
    func push(count: Int, projectName: String?, status: String) {
        var payload: [String: Any] = ["active": true, "count": count, "status": status]
        if let projectName { payload["project"] = projectName }
        send(payload)
    }

    private func send(_ payload: [String: Any], force: Bool = false) {
        // Gleicher Stand wie zuletzt? Dann nichts schicken – der Status
        // ändert sich beim Stabilisieren bis zu zehnmal je Sekunde, ohne dass
        // sich an der Uhr etwas ändert. Spart Akku auf beiden Geräten.
        if !force, NSDictionary(dictionary: payload).isEqual(to: lastPayload) { return }
        lastPayload = payload
        guard let session, session.activationState == .activated else { return }
        try? session.updateApplicationContext(payload)
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
    }

    /// Nach dem Wiederverbinden den aktuellen Stand nachschicken – sonst
    /// zeigt die Uhr „0" und „Bereit", auch mitten in einer Sitzung.
    fileprivate func resend() {
        send(lastPayload, force: true)
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            WatchLink.shared.isReachable = session.isReachable
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            WatchLink.shared.isReachable = session.isReachable
            if session.isReachable { WatchLink.shared.resend() }
        }
    }

    /// Befehl mit Rückmeldung: Die Watch erfährt, ob wirklich ausgelöst
    /// wurde – sonst klickte sie, auch wenn am iPhone kein Sucher offen ist.
    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let command = message["command"] as? String
        Task { @MainActor in
            let link = WatchLink.shared
            let handler: (() -> Void)? = switch command {
            case "shutter": link.onShutter
            case "finish": link.onFinish
            default: nil
            }
            handler?()
            replyHandler(["ok": handler != nil])
        }
    }

    // Ältere Watch-Fassungen schicken ohne Rückmeldung.
    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            switch message["command"] as? String {
            case "shutter": WatchLink.shared.onShutter?()
            case "finish":  WatchLink.shared.onFinish?()
            default: break
            }
        }
    }

    // Auf iOS Pflicht, auf watchOS nicht vorhanden.
    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
