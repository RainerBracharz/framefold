import SwiftUI
import UIKit

/// Text, Sprechblasen und Zeichnen auf einem Bild. Jede Einblendung gilt ab
/// diesem Bild für einen wählbaren Bereich – eine Sprechblase bleibt so lange
/// stehen, wie die Figur spricht.
struct OverlayEditorView: View {
    @EnvironmentObject var store: ProjectStore
    let projectID: UUID
    let frameIndex: Int
    let onClose: () -> Void

    private enum Tool: String, CaseIterable, Identifiable {
        case select, text, bubble, pen
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .select: return "hand.point.up.left"
            case .text: return "textformat"
            case .bubble: return "bubble.left"
            case .pen: return "pencil.tip"
            }
        }
        var label: LocalizedStringKey {
            switch self {
            case .select: return "Auswählen"
            case .text: return "Text"
            case .bubble: return "Sprechblase"
            case .pen: return "Stift"
            }
        }
    }

    @State private var tool: Tool = .text
    @State private var selectedID: UUID?
    @State private var image: UIImage?
    @State private var penColor: OverlayColor = .amber
    @State private var penWidth = 0.008
    @State private var liveStroke: [CGPoint] = []
    @State private var dragOffset: CGSize?

    private var project: Project? { store.projects.first { $0.id == projectID } }
    private var frameCount: Int { project?.frameCount ?? 1 }
    private var overlays: [FrameOverlay] { (project?.overlays ?? []).filter { $0.covers(frameIndex) } }
    private var selected: FrameOverlay? { project?.overlays?.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                let rect = imageRect(in: geo.size)
                ZStack(alignment: .topLeading) {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                    Canvas { ctx, _ in
                        ctx.withCGContext { cg in
                            cg.translateBy(x: rect.minX, y: rect.minY)
                            var shown = overlays
                            if liveStroke.count > 0 {
                                shown.append(FrameOverlay(kind: .drawing, firstFrame: frameIndex, lastFrame: frameIndex,
                                                          strokes: [OverlayStroke(points: liveStroke, width: penWidth, color: penColor)]))
                            }
                            OverlayRenderer.draw(shown, in: cg, size: rect.size)
                            if let selected, selected.kind != .drawing {
                                let r = OverlayRenderer.frame(of: selected, size: rect.size).insetBy(dx: -6, dy: -6)
                                cg.setStrokeColor(UIColor.ffAmber.cgColor)
                                cg.setLineWidth(2)
                                cg.setLineDash(phase: 0, lengths: [6, 4])
                                cg.stroke(r)
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in dragChanged(value, rect: rect) }
                    .onEnded { value in dragEnded(value, rect: rect) })
            }
            .background(Color.black)
            inspector
        }
        .frame(minWidth: 640, minHeight: 600)
        .background(Theme.darkroom)
        .preferredColorScheme(.dark)
        .task { loadImage() }
    }

    // MARK: Kopf und Werkzeuge

    private var header: some View {
        HStack(spacing: 8) {
            Text("Bild \(frameIndex + 1)").font(Theme.caption(12)).tracking(1.2).textCase(.uppercase)
            Spacer()
            ForEach(Tool.allCases) { t in
                Button { tool = t } label: {
                    Image(systemName: t.symbol)
                        .frame(width: 40, height: 34)
                        .background(tool == t ? Theme.amber : Color.clear)
                        .foregroundStyle(tool == t ? Color.black : Theme.paperOnDark)
                }
                .buttonStyle(.plain)
                .help(Text(t.label))
                .accessibilityLabel(Text(t.label))
            }
            Spacer()
            Button("Fertig", action: onClose).font(Theme.caption(12)).keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.paperOnDark)
        .padding(12)
    }

    @ViewBuilder
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            if tool == .pen {
                HStack {
                    colorSwatches(selection: penColor) { penColor = $0 }
                    Spacer()
                    Text("Stärke").font(Theme.mono(11))
                    Slider(value: $penWidth, in: 0.003...0.03).frame(maxWidth: 160)
                }
                HStack {
                    Button("Letzten Strich zurück") { undoStroke() }
                    Spacer()
                    Text("Zeichnung gilt für dieses Bild.").font(Theme.mono(10)).opacity(0.6)
                }
                .font(Theme.mono(11))
            } else if let selected {
                if selected.kind != .drawing {
                    TextField("Text", text: Binding(get: { selected.text },
                                                    set: { new in update { $0.text = new } }), axis: .vertical)
                        .lineLimit(1...4)
                        .font(Theme.body)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        colorSwatches(selection: selected.color) { c in update { $0.color = c } }
                        Spacer()
                        Text("Größe").font(Theme.mono(11))
                        Slider(value: Binding(get: { selected.size }, set: { v in update { $0.size = v } }),
                               in: 0.025...0.15).frame(maxWidth: 160)
                    }
                }
                HStack {
                    Stepper(value: Binding(get: { selected.lastFrame + 1 },
                                           set: { v in update { $0.lastFrame = max($0.firstFrame, min(frameCount - 1, v - 1)) } }),
                            in: (selected.firstFrame + 1)...max(selected.firstFrame + 1, frameCount)) {
                        Text("Bild \(selected.firstFrame + 1) bis \(selected.lastFrame + 1)").font(Theme.mono(11))
                    }
                    Spacer()
                    Button(role: .destructive) {
                        store.removeOverlay(id: selected.id, in: projectID)
                        selectedID = nil
                    } label: { Label("Entfernen", systemImage: "trash") }
                }
                .font(Theme.mono(11))
            } else {
                Text(tool == .select
                     ? "Text oder Sprechblase antippen, um sie zu bearbeiten oder zu verschieben."
                     : "Ins Bild tippen, wo der Text stehen soll.")
                    .font(Theme.mono(11)).opacity(0.7)
            }
        }
        .foregroundStyle(Theme.paperOnDark)
        .padding(14)
    }

    private func colorSwatches(selection: OverlayColor, choose: @escaping (OverlayColor) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(OverlayColor.allCases) { c in
                Button { choose(c) } label: {
                    Circle().fill(Color(uiColor: c.ui))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(selection == c ? Theme.amber : Color.white.opacity(0.3),
                                                 lineWidth: selection == c ? 3 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: c.rawValue))
            }
        }
    }

    // MARK: Gesten

    private func normalized(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (p.x - rect.minX) / rect.width)),
                y: min(1, max(0, (p.y - rect.minY) / rect.height)))
    }

    private func dragChanged(_ value: DragGesture.Value, rect: CGRect) {
        let p = normalized(value.location, in: rect)
        switch tool {
        case .pen:
            liveStroke.append(p)
        case .select:
            if dragOffset == nil {
                selectedID = hit(normalized(value.startLocation, in: rect), rect: rect)?.id
                dragOffset = .zero
            }
            if selected != nil, value.translation != .zero {
                let start = normalized(value.startLocation, in: rect)
                if let original = overlays.first(where: { $0.id == selectedID }) {
                    let dx = p.x - start.x, dy = p.y - start.y
                    if dragOffset == .zero { dragOffset = CGSize(width: original.x, height: original.y) }
                    let base = dragOffset ?? .zero
                    update { $0.x = min(1, max(0, base.width + dx)); $0.y = min(1, max(0, base.height + dy)) }
                }
            }
        case .text, .bubble:
            break
        }
    }

    private func dragEnded(_ value: DragGesture.Value, rect: CGRect) {
        let p = normalized(value.location, in: rect)
        switch tool {
        case .pen:
            commitStroke()
        case .select:
            dragOffset = nil
        case .text, .bubble:
            if let existing = hit(p, rect: rect) {
                selectedID = existing.id
            } else {
                let overlay = FrameOverlay(kind: tool == .text ? .text : .bubble,
                                           firstFrame: frameIndex,
                                           lastFrame: min(frameCount - 1, frameIndex + 11),
                                           x: p.x, y: p.y,
                                           text: tool == .text ? String(localized: "Text") : String(localized: "Hallo!"),
                                           size: 0.06,
                                           color: tool == .text ? .white : .white)
                store.upsertOverlay(overlay, in: projectID)
                selectedID = overlay.id
            }
            tool = .select
        }
    }

    private func hit(_ p: CGPoint, rect: CGRect) -> FrameOverlay? {
        let point = CGPoint(x: p.x * rect.width, y: p.y * rect.height)
        return overlays.last { $0.kind != .drawing && OverlayRenderer.frame(of: $0, size: rect.size).insetBy(dx: -10, dy: -10).contains(point) }
    }

    private func commitStroke() {
        guard !liveStroke.isEmpty else { return }
        let stroke = OverlayStroke(points: liveStroke, width: penWidth, color: penColor)
        liveStroke = []
        // Alle Striche dieses Bilds liegen in einer Zeichnung
        if var drawing = (project?.overlays ?? []).first(where: { $0.kind == .drawing && $0.firstFrame == frameIndex && $0.lastFrame == frameIndex }) {
            drawing.strokes.append(stroke)
            store.upsertOverlay(drawing, in: projectID)
        } else {
            store.upsertOverlay(FrameOverlay(kind: .drawing, firstFrame: frameIndex, lastFrame: frameIndex, strokes: [stroke]),
                                in: projectID)
        }
    }

    private func undoStroke() {
        guard var drawing = (project?.overlays ?? []).first(where: { $0.kind == .drawing && $0.firstFrame == frameIndex && $0.lastFrame == frameIndex }) else { return }
        drawing.strokes.removeLast()
        if drawing.strokes.isEmpty { store.removeOverlay(id: drawing.id, in: projectID) } else { store.upsertOverlay(drawing, in: projectID) }
    }

    private func update(_ change: (inout FrameOverlay) -> Void) {
        guard var overlay = selected else { return }
        change(&overlay)
        store.upsertOverlay(overlay, in: projectID)
    }

    // MARK: Bild

    private func imageRect(in size: CGSize) -> CGRect {
        guard let image, image.size.width > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let w = image.size.width * scale, h = image.size.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func loadImage() {
        guard let project else { return }
        let urls = store.frameURLs(for: project)
        guard urls.indices.contains(frameIndex) else { return }
        image = UIImage.thumbnail(at: urls[frameIndex], maxPixelSize: 1600)
    }
}

/// Einblendungen über einem Bild im Studio-Betrachter.
struct OverlayLayer: View {
    let overlays: [FrameOverlay]
    var body: some View {
        Canvas { ctx, size in
            ctx.withCGContext { cg in OverlayRenderer.draw(overlays, in: cg, size: size) }
        }
        .allowsHitTesting(false)
    }
}
