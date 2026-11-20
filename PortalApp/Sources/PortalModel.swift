import Foundation
import Network
import Observation
import PortalKit
import Security
import UIKit

/// État de l'app iPhone : appairage, Mac trouvé sur le réseau, envois en cours.
@MainActor
@Observable
final class PortalModel {
    enum SendState: Equatable {
        case idle
        case sending(name: String, progress: Double)
        case done(String)
        case failed(String)
    }

    private(set) var pairing: PortalPairing?
    private(set) var macs: [PortalBrowser.Found] = []
    var state: SendState = .idle

    private let browser = PortalBrowser()

    init() {
        pairing = PhoneKeychain.load()
        // Tests sur simulateur : `-pairLink <lien>` appaire sans scanner.
        if let link = UserDefaults.standard.string(forKey: "pairLink"), let url = URL(string: link) {
            _ = pair(with: url)
        }
        browser.onChange = { [weak self] found in
            DispatchQueue.main.async { self?.macs = found }
        }
        browser.start()
    }

    var isPaired: Bool { pairing != nil }

    /// Le Mac appairé, s'il est visible sur le réseau.
    var pairedMac: PortalBrowser.Found? {
        guard let pairing else { return nil }
        return macs.first { $0.name == pairing.macName } ?? (macs.count == 1 ? macs.first : nil)
    }

    /// Override de debug (`-portalHost 127.0.0.1 -portalPort 1234`) pour viser un port précis.
    private var debugEndpoint: NWEndpoint? {
        let d = UserDefaults.standard
        guard let host = d.string(forKey: "portalHost"), d.integer(forKey: "portalPort") > 0,
              let port = NWEndpoint.Port(rawValue: UInt16(d.integer(forKey: "portalPort"))) else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }

    var canSend: Bool { pairing != nil && (pairedMac != nil || debugEndpoint != nil) }

    @discardableResult
    func pair(with url: URL) -> Bool {
        guard let p = PortalPairing(url: url) else { return false }
        pairing = p
        PhoneKeychain.save(p)
        return true
    }

    func unpair() {
        pairing = nil
        PhoneKeychain.delete()
    }

    // MARK: Envois

    func sendFile(_ url: URL, displayName: String, transition: String) async {
        await withClient(name: displayName) { client in
            let name = try await client.sendFile(url, name: displayName, transition: transition) { p in
                Task { @MainActor in self.state = .sending(name: displayName, progress: p) }
            }
            return "« \(name) » est sur ton Mac"
        }
    }

    func sendClipboard(transition: String) async {
        let pb = UIPasteboard.general
        if let text = pb.string, !text.isEmpty {
            await withClient(name: "Presse-papiers") { client in
                try await client.sendText(text, transition: transition)
                return "Texte copié sur le Mac"
            }
        } else if let image = pb.image, let data = image.pngData() {
            await withClient(name: "Image") { client in
                try await client.sendImage(data, uti: "public.png", transition: transition)
                return "Image copiée sur le Mac"
            }
        } else {
            state = .failed("Le presse-papiers est vide")
        }
    }

    private func withClient(name: String, _ body: @escaping (PortalClient) async throws -> String) async {
        guard let pairing, let endpoint = debugEndpoint ?? pairedMac?.endpoint else {
            state = .failed("Mac introuvable sur le réseau")
            return
        }
        state = .sending(name: name, progress: 0)
        let client = PortalClient(endpoint: endpoint, key: pairing.key, senderName: UIDevice.current.name)
        do {
            try await client.connect()
            let message = try await body(client)
            client.close()
            state = .done(message)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            client.close()
            state = .failed(error.localizedDescription)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

/// Appairage stocké dans le trousseau de l'iPhone.
enum PhoneKeychain {
    private static let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: "dev.island.portal",
                                              kSecAttrAccount as String: "pairing"]

    static func load() -> PortalPairing? {
        var q = base
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let s = String(data: data, encoding: .utf8), let url = URL(string: s) else { return nil }
        return PortalPairing(url: url)
    }

    static func save(_ p: PortalPairing) {
        delete()
        var add = base
        add[kSecValueData as String] = Data(p.url.absoluteString.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func delete() { SecItemDelete(base as CFDictionary) }
}
