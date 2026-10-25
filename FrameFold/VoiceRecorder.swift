import AVFoundation
import SwiftUI

/// Nimmt Stimme oder Geräusche über das Mikrofon auf – nur in eine Datei auf
/// dem Gerät, nichts verlässt es.
@MainActor
final class VoiceRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var denied = false

    private var recorder: AVAudioRecorder?
    private var meter: Timer?
    private(set) var url: URL?

    /// Fragt einmal um Erlaubnis. Ohne Erlaubnis bleibt alles andere nutzbar.
    func requestPermission() async -> Bool {
        let granted = await AVAudioApplication.requestRecordPermission()
        denied = !granted
        return granted
    }

    func start() -> Bool {
        #if !targetEnvironment(macCatalyst)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
        #endif
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-stimme-\(UUID().uuidString.prefix(8)).m4a")
        guard let recorder = try? AVAudioRecorder(url: target, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]) else { return false }
        recorder.isMeteringEnabled = true
        guard recorder.record() else { return false }
        self.recorder = recorder
        url = target
        isRecording = true
        elapsed = 0
        meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMeter() }
        }
        return true
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        meter?.invalidate()
        meter = nil
        isRecording = false
        level = 0
        #if !targetEnvironment(macCatalyst)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func updateMeter() {
        guard let recorder else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        // dB (−60…0) → 0…1
        level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 60) / 60))
    }
}

/// Aufnahme zum laufenden Film: Ab Bild `startFrame` spielt der Film in der
/// Bildrate, nach „3 – 2 – 1“ läuft die Aufnahme mit. So passt die Stimme
/// zur Bewegung, ohne nachträglich verschoben zu werden.
struct VoiceRecordSheet: View {
    let urls: [URL]
    let startFrame: Int
    let fps: Int32
    /// Übernehmen: Datei und Einsatzbild
    let onDone: (URL?, Int) -> Void

    @StateObject private var recorder = VoiceRecorder()
    @State private var images: [UIImage?] = []
    @State private var countdown: Int?
    @State private var startDate: Date?
    @State private var finished = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Stimme aufnehmen").font(Theme.caption(12)).tracking(1.4).textCase(.uppercase)
                Spacer()
                Text("ab Bild \(startFrame + 1)").font(Theme.mono(11))
            }
            .foregroundStyle(Theme.paperOnDark)

            ZStack {
                Rectangle().fill(Color.black)
                TimelineView(.periodic(from: .now, by: 1 / Double(max(1, fps)))) { context in
                    if let image = frameImage(at: context.date) {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                }
                if let countdown {
                    Text("\(countdown)").font(.system(size: 96, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.amber)
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.3), lineWidth: 1))

            // Pegel und Zeit
            HStack(spacing: 10) {
                Image(systemName: recorder.isRecording ? "mic.fill" : "mic")
                    .foregroundStyle(recorder.isRecording ? Color.red : Theme.paperOnDark)
                GeometryReader { geo in
                    Rectangle().fill(Theme.amber)
                        .frame(width: geo.size.width * CGFloat(recorder.level))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 8)
                .background(Color.white.opacity(0.08))
                Text(String(format: "%.1f s", recorder.elapsed)).font(Theme.mono(11))
                    .foregroundStyle(Theme.paperOnDark)
            }

            if recorder.denied {
                Text("Kein Mikrofonzugriff – erlauben unter Einstellungen → Datenschutz → Mikrofon.")
                    .font(Theme.mono(11)).foregroundStyle(Theme.oxblood)
            }

            HStack(spacing: 10) {
                if recorder.isRecording {
                    Button("Stopp") { stop() }.buttonStyle(DarkPrimaryButtonStyle())
                } else if finished {
                    Button("Nochmal") { finished = false; begin() }.buttonStyle(DarkSecondaryButtonStyle())
                    Button("Übernehmen") { onDone(recorder.url, startFrame) }.buttonStyle(DarkPrimaryButtonStyle())
                } else {
                    Button(countdown == nil ? "Aufnahme starten" : "…") { begin() }
                        .buttonStyle(DarkPrimaryButtonStyle())
                        .disabled(countdown != nil)
                }
                Button("Abbrechen", role: .cancel) {
                    if recorder.isRecording { recorder.stop() }
                    onDone(nil, startFrame)
                }
                .buttonStyle(DarkSecondaryButtonStyle())
            }
            Text("Der Film läuft ab Bild \(startFrame + 1) mit. Vorhandener Ton spielt während der Aufnahme nicht, damit er nicht mit aufgenommen wird.")
                .font(Theme.mono(10)).foregroundStyle(Theme.paperOnDark.opacity(0.55))
        }
        .padding(20)
        .frame(minWidth: 520)
        .background(Theme.darkroom)
        .preferredColorScheme(.dark)
        .task { await loadImages() }
        .onDisappear { if recorder.isRecording { recorder.stop() } }
    }

    /// Bild, das zu diesem Zeitpunkt der Aufnahme läuft (vorher: das Startbild).
    private func frameImage(at date: Date) -> UIImage? {
        guard !images.isEmpty else { return nil }
        var index = 0
        if let startDate, recorder.isRecording {
            index = Int(date.timeIntervalSince(startDate) * Double(fps))
        }
        return images[min(images.count - 1, max(0, index))]
    }

    private func loadImages() async {
        let slice = Array(urls.dropFirst(startFrame))
        let loaded = await Task.detached(priority: .userInitiated) {
            slice.map { UIImage.thumbnail(at: $0, maxPixelSize: 900) }
        }.value
        images = loaded
    }

    private func begin() {
        Task {
            guard await recorder.requestPermission() else { return }
            for n in [3, 2, 1] {
                countdown = n
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            countdown = nil
            if recorder.start() { startDate = Date() }
        }
    }

    private func stop() {
        recorder.stop()
        startDate = nil
        finished = true
    }
}
