import PhotosUI
import PortalKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct IslandPortalApp: App {
    @State private var model = PortalModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                // Lien d'appairage ouvert depuis l'appareil photo (islandportal://pair?…).
                .onOpenURL { model.pair(with: $0) }
        }
    }
}

struct ContentView: View {
    @Environment(PortalModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.isPaired {
                    SendView()
                } else {
                    PairingView()
                }
            }
            .navigationTitle("Portal")
        }
    }
}

// MARK: - Appairage

struct PairingView: View {
    @Environment(PortalModel.self) private var model
    @State private var scanning = false
    @State private var link = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 64)).foregroundStyle(.tint)
            Text("Sur ton Mac : Island → Réglages → Portal, puis scanne le QR code.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                scanning = true
            } label: {
                Label("Scanner le QR code", systemImage: "camera.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            VStack(alignment: .leading, spacing: 8) {
                Text("Ou colle le lien d'appairage").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    TextField("islandportal://pair?…", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button("OK") {
                        if let url = URL(string: link.trimmingCharacters(in: .whitespaces)), model.pair(with: url) {
                            error = nil
                        } else {
                            error = "Lien invalide"
                        }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .padding(28)
        .sheet(isPresented: $scanning) {
            QRScannerView { code in
                scanning = false
                if let url = URL(string: code), model.pair(with: url) { error = nil } else { error = "Ce QR code n'est pas celui d'Island" }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Envoi

struct SendView: View {
    @Environment(PortalModel.self) private var model
    @AppStorage("transition") private var transition = "slide"
    @State private var photoItem: PhotosPickerItem?
    @State private var importing = false
    @State private var staged: StagedFile?
    @State private var dragX: CGFloat = 0
    @State private var flying = false

    var body: some View {
        VStack(spacing: 18) {
            status

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                    .foregroundStyle(.tertiary)
                if let staged {
                    StagedCard(file: staged)
                        .offset(x: flying ? -600 : dragX)
                        .rotationEffect(.degrees(Double(dragX) / 25))
                        .gesture(
                            DragGesture()
                                .onChanged { dragX = min(0, $0.translation.width) }
                                .onEnded { v in
                                    if v.translation.width < -120 || v.predictedEndTranslation.width < -300 { send(staged) }
                                    else { withAnimation(.spring) { dragX = 0 } }
                                }
                        )
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.left.to.line").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Choisis une photo ou un fichier,\npuis lance-le vers la gauche")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 300)

            HStack(spacing: 12) {
                PhotosPicker(selection: $photoItem, matching: .any(of: [.images, .videos])) {
                    Label("Photos", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                }
                Button { importing = true } label: {
                    Label("Fichiers", systemImage: "folder").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                Task { await model.sendClipboard(transition: transition) }
            } label: {
                Label("Envoyer le presse-papiers", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canSend)

            Picker("Animation sur le Mac", selection: $transition) {
                Text("Glissement").tag("slide")
                Text("Avion en papier").tag("plane")
                Text("Rebond").tag("bounce")
            }
            .pickerStyle(.segmented)

            Spacer()
        }
        .padding(20)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let p = model.pairing {
                        Text("Mac : \(p.macName)")
                        Text("Empreinte : \(p.fingerprint)")
                    }
                    Button("Oublier ce Mac", role: .destructive) { model.unpair() }
                } label: { Image(systemName: "laptopcomputer") }
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { staged = await StagedFile.load(item); photoItem = nil }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { staged = StagedFile.copy(url) }
        }
        .task {
            // Test sur simulateur : `-autoSendText "…"` envoie du texte au lancement.
            if let text = UserDefaults.standard.string(forKey: "autoSendText") {
                try? await Task.sleep(for: .seconds(2))
                UIPasteboard.general.string = text
                await model.sendClipboard(transition: transition)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 8) {
            Circle().fill(model.canSend ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(model.canSend ? "Connecté à \(model.pairedMac?.name ?? model.pairing?.macName ?? "ton Mac")"
                               : "Recherche de \(model.pairing?.macName ?? "ton Mac")…")
                .font(.subheadline)
            Spacer()
        }
        switch model.state {
        case .sending(let name, let p):
            ProgressView(value: p) { Text("Envoi de \(name)").font(.footnote) }
        case .done(let m):
            Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote)
        case .failed(let m):
            Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote)
        case .idle:
            EmptyView()
        }
    }

    private func send(_ file: StagedFile) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeIn(duration: 0.35)) { flying = true }
        Task {
            await model.sendFile(file.url, displayName: file.name, transition: transition)
            try? await Task.sleep(for: .milliseconds(300))
            staged = nil
            flying = false
            dragX = 0
        }
    }
}

/// Fichier prêt à partir (copié dans le dossier temporaire de l'app).
struct StagedFile: Equatable {
    let url: URL
    let name: String
    let preview: UIImage?

    static func copy(_ src: URL) -> StagedFile? {
        let access = src.startAccessingSecurityScopedResource()
        defer { if access { src.stopAccessingSecurityScopedResource() } }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(src.lastPathComponent)
        try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? FileManager.default.copyItem(at: src, to: dst)) != nil else { return nil }
        return StagedFile(url: dst, name: src.lastPathComponent, preview: UIImage(contentsOfFile: dst.path))
    }

    static func load(_ item: PhotosPickerItem) async -> StagedFile? {
        if let movie = try? await item.loadTransferable(type: MovieFile.self) {
            return StagedFile(url: movie.url, name: movie.url.lastPathComponent, preview: nil)
        }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let type = item.supportedContentTypes.first
        let ext = type?.preferredFilenameExtension ?? "jpg"
        let name = "Photo \(Date().formatted(.dateTime.year().month().day().hour().minute().second())).\(ext)"
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        guard (try? data.write(to: url)) != nil else { return nil }
        return StagedFile(url: url, name: name, preview: UIImage(data: data))
    }
}

/// Vidéo exportée par PhotosPicker vers un fichier (évite de charger toute la vidéo en mémoire).
struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: received.file, to: dst)
            return MovieFile(url: dst)
        }
    }
}

struct StagedCard: View {
    let file: StagedFile

    var body: some View {
        VStack(spacing: 10) {
            if let img = file.preview {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 220, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Image(systemName: "doc.fill").font(.system(size: 60)).foregroundStyle(.tint)
            }
            Text(file.name).font(.footnote.weight(.semibold)).lineLimit(1)
            Text("← Glisse vers la gauche pour envoyer").font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
