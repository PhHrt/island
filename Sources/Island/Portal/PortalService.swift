import AppKit
import Foundation
import Observation
import PortalKit
import QuickLookThumbnailing
import Security

/// Dernier élément reçu, affiché dans l'île ouverte (glissable vers le Finder ou une app).
struct PortalItem: Equatable, Identifiable {
    let id = UUID()
    let url: URL?
    let name: String
    let kind: PortalKind
    let thumbnail: NSImage?
    let transition: String
    let date = Date()
}

/// Côté Mac de Portal : clé d'appairage (trousseau), serveur, rangement et annonce des réceptions.
@MainActor
@Observable
final class PortalService {
    static let shared = PortalService()

    private(set) var pairing: PortalPairing
    private(set) var isRunning = false
    private(set) var port: UInt16?
    private(set) var lastError: String?
    private(set) var progress: (name: String, fraction: Double)?
    var recent: PortalItem?

    @ObservationIgnored weak var model: IslandModel?
    @ObservationIgnored var onArrival: ((PortalItem) -> Void)?
    @ObservationIgnored private var server: PortalServer?

    static var macName: String { Host.current().localizedName ?? "Mac" }

    private init() {
        pairing = Keychain.loadPairing() ?? {
            let p = PortalPairing.generate(macName: PortalService.macName)
            Keychain.save(p)
            return p
        }()
    }

    var destination: URL {
        if let path = UserDefaults.standard.string(forKey: Prefs.Key.portalFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    func applyPreference() {
        Prefs.portal ? start() : stop()
    }

    func start() {
        guard server == nil else { return }
        let server = PortalServer(key: pairing.key, serviceName: pairing.macName, destination: destination)
        server.onReceive = { [weak self] item in DispatchQueue.main.async { self?.received(item) } }
        server.onProgress = { [weak self] name, done, total in
            DispatchQueue.main.async {
                guard let self else { return }
                self.progress = done >= total ? nil : (name, total > 0 ? Double(done) / Double(total) : 0)
            }
        }
        self.server = server
        Task {
            do {
                try await server.start()
                isRunning = true
                port = server.port
                lastError = nil
                DebugLog.write("portal: écoute sur le port \(server.port ?? 0)")
            } catch {
                lastError = error.localizedDescription
                self.server = nil
            }
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        port = nil
    }

    /// Nouvelle clé : l'iPhone devra rescanner le QR code.
    func regenerateKey() {
        pairing = PortalPairing.generate(macName: Self.macName)
        Keychain.save(pairing)
        stop()
        applyPreference()
    }

    func restart() {
        stop()
        applyPreference()
    }

    private func received(_ r: PortalReceived) {
        let item: PortalItem
        switch r {
        case .file(let url, let h):
            // Photo : on montre l'image elle-même tout de suite ; sinon l'icône, puis la vignette Quick Look.
            let isSmallImage = ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(url.pathExtension.lowercased())
                && h.size < 40 * 1024 * 1024
            let preview = isSmallImage ? NSImage(contentsOf: url) : nil
            item = PortalItem(url: url, name: url.lastPathComponent, kind: .file,
                              thumbnail: preview ?? NSWorkspace.shared.icon(forFile: url.path), transition: h.transition ?? "slide")
            recent = item
            generateThumbnail(for: url, itemID: item.id)
        case .text(let text, let h):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            item = PortalItem(url: nil, name: String(text.prefix(60)), kind: .clipboardText, thumbnail: nil,
                              transition: h.transition ?? "slide")
        case .image(let data, let h):
            let image = NSImage(data: data)
            NSPasteboard.general.clearContents()
            if let image { NSPasteboard.general.writeObjects([image]) }
            item = PortalItem(url: nil, name: "Image", kind: .clipboardImage, thumbnail: image, transition: h.transition ?? "slide")
        }
        DebugLog.write("portal: reçu \(item.kind.rawValue) \(item.name)")
        if Prefs.haptics { Haptics.tap() }
        model?.post(Toast(kind: .portal(name: item.name, symbol: Self.symbol(for: item))))
        onArrival?(item)
    }

    static func symbol(for item: PortalItem) -> String {
        switch item.kind {
        case .clipboardText: return "doc.on.clipboard.fill"
        case .clipboardImage: return "photo.on.rectangle"
        default:
            let ext = item.url?.pathExtension.lowercased() ?? ""
            if ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(ext) { return "photo.fill" }
            if ["mov", "mp4", "m4v"].contains(ext) { return "video.fill" }
            return "doc.fill"
        }
    }

    private func generateThumbnail(for url: URL, itemID: UUID) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 240, height: 240), scale: 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let r = self.recent, r.id == itemID else { return }
                self.recent = PortalItem(url: r.url, name: r.name, kind: r.kind, thumbnail: image, transition: r.transition)
            }
        }
    }
}

/// Stockage de la clé d'appairage dans le trousseau macOS.
enum Keychain {
    private static let service = "dev.island.portal"
    private static let account = "pairing"

    static func loadPairing() -> PortalPairing? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let s = String(data: data, encoding: .utf8), let url = URL(string: s) else { return nil }
        return PortalPairing(url: url)
    }

    static func save(_ p: PortalPairing) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(p.url.absoluteString.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
