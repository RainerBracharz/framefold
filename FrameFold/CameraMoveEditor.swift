import SwiftUI

/// Kamerafahrten bearbeiten: Bildbereich, Start- und Ziel-Ausschnitt.
/// Gezogen wird der Ausschnitt mit dem Finger, gezoomt mit dem Regler.
struct CameraMoveEditor: View {
    @EnvironmentObject var store: ProjectStore
    let projectID: UUID
    let onClose: () -> Void

    @State private var selectedID: UUID?

    private var project: Project? { store.projects.first { $0.id == projectID } }
    private var moves: [CameraMove] { (project?.cameraMoves ?? []).sorted { $0.firstFrame < $1.firstFrame } }
    private var frameCount: Int { project?.frameCount ?? 0 }
    private var selected: CameraMove? { moves.first { $0.id == selectedID } ?? moves.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Schwenk und Zoom über einen Bildbereich – im Export, wie eine Kamerabewegung über das Set.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.graphite)
                    if !moves.isEmpty {
                        Picker("Kamerafahrt", selection: Binding(get: { selected?.id ?? UUID() }, set: { selectedID = $0 })) {
                            ForEach(moves) { m in
                                Text("Bild \(m.firstFrame + 1) bis \(m.lastFrame + 1)").tag(m.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    if let move = selected { editor(move) }
                    HStack {
                        Button { add() } label: { Label("Neue Kamerafahrt", systemImage: "plus") }
                            .disabled(frameCount < 2)
                        Spacer()
                        if let move = selected {
                            Button(role: .destructive) { remove(move) } label: { Label("Entfernen", systemImage: "trash") }
                        }
                    }
                    .font(Theme.body)
                }
                .padding(20)
            }
            .background(Theme.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { CatalogLabel("Kamerafahrt", color: Theme.ink, size: 12) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig", action: onClose).foregroundStyle(Theme.ink)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 640)
    }

    @ViewBuilder
    private func editor(_ move: CameraMove) -> some View {
        let urls = project.map { store.frameURLs(for: $0) } ?? []
        VStack(alignment: .leading, spacing: 12) {
            Stepper(value: Binding(get: { move.firstFrame + 1 },
                                   set: { v in update(move) { $0.firstFrame = min(max(0, v - 1), $0.lastFrame) } }),
                    in: 1...max(1, frameCount)) {
                Text("Von Bild \(move.firstFrame + 1)").font(Theme.body)
            }
            Stepper(value: Binding(get: { move.lastFrame + 1 },
                                   set: { v in update(move) { $0.lastFrame = max(min(frameCount - 1, v - 1), $0.firstFrame) } }),
                    in: 1...max(1, frameCount)) {
                Text("Bis Bild \(move.lastFrame + 1)").font(Theme.body)
            }
            Toggle(isOn: Binding(get: { move.smooth }, set: { v in update(move) { $0.smooth = v } })) {
                Text("Weich anfahren und abbremsen").font(Theme.body)
            }
            HStack(alignment: .top, spacing: 12) {
                FramingPicker(title: "Anfang",
                              url: urls.indices.contains(move.firstFrame) ? urls[move.firstFrame] : nil,
                              framing: Binding(get: { move.from }, set: { f in update(move) { $0.from = f } }))
                FramingPicker(title: "Ende",
                              url: urls.indices.contains(move.lastFrame) ? urls[move.lastFrame] : nil,
                              framing: Binding(get: { move.to }, set: { f in update(move) { $0.to = f } }))
            }
        }
        .tint(Theme.ink)
    }

    private func add() {
        let start = (moves.last.map { $0.lastFrame + 1 } ?? 0)
        let first = start < frameCount - 1 ? start : 0
        let move = CameraMove(firstFrame: first, lastFrame: min(frameCount - 1, first + 23))
        store.setCameraMoves(moves + [move], in: projectID)
        selectedID = move.id
    }

    private func remove(_ move: CameraMove) {
        store.setCameraMoves(moves.filter { $0.id != move.id }, in: projectID)
        selectedID = nil
    }

    private func update(_ move: CameraMove, _ change: (inout CameraMove) -> Void) {
        var changed = move
        change(&changed)
        store.setCameraMoves(moves.map { $0.id == move.id ? changed : $0 }, in: projectID)
    }
}

/// Ein Bild mit dem Ausschnitt als Rahmen: ziehen verschiebt, Regler zoomt.
private struct FramingPicker: View {
    let title: LocalizedStringKey
    let url: URL?
    @Binding var framing: Framing
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.caption(11)).tracking(1.2).textCase(.uppercase).foregroundStyle(Theme.graphite)
            GeometryReader { geo in
                let size = fitted(in: geo.size)
                let rect = framing.rect(in: size)
                ZStack(alignment: .topLeading) {
                    if let image {
                        Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                    } else {
                        Rectangle().fill(Theme.paperShade).frame(width: size.width, height: size.height)
                    }
                    Rectangle().fill(Color.black.opacity(0.45)).frame(width: size.width, height: size.height)
                        .mask(Rectangle().frame(width: size.width, height: size.height)
                            .overlay(Rectangle().frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY).blendMode(.destinationOut)))
                    Rectangle().stroke(Theme.amber, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                .frame(width: size.width, height: size.height)
                .compositingGroup()
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    framing.x = min(max(0, value.location.x / size.width), 1)
                    framing.y = min(max(0, value.location.y / size.height), 1)
                })
            }
            .aspectRatio(aspect, contentMode: .fit)
            HStack {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $framing.zoom, in: 1...4)
                Image(systemName: "plus.magnifyingglass")
            }
            .foregroundStyle(Theme.graphite)
        }
        .task(id: url) {
            guard let url else { return }
            image = await Task.detached { UIImage.thumbnail(at: url, maxPixelSize: 600) }.value
        }
    }

    private var aspect: CGFloat {
        guard let image, image.size.height > 0 else { return 4 / 3 }
        return image.size.width / image.size.height
    }

    private func fitted(in size: CGSize) -> CGSize {
        let w = min(size.width, size.height * aspect)
        return CGSize(width: w, height: w / aspect)
    }
}
