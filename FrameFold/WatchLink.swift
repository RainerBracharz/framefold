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

    /// Session beendet – die Uhr zurücksetzen, statt den letzten Stand
    /// stehenzulassen.
    func pushSessionEnded() {
        guard let session, session.isReachable else { return }
        session.sendMessage(["reset": true, "count": 0, "status": "Bereit"],
                            replyHandler: nil, errorHandler: nil)
    }

    /// Zählerstand und Werkname ans Handgelenk melden.
    func push(count: Int, projectName: String?, status: String) {
        guard let session, session.isReachable else { return }
        var payload: [String: Any] = ["count": count, "status": status]
        if let projectName { payload["project"] = projectName }
        session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
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
        }
    }

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
