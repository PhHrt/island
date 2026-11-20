import CryptoKit
import Foundation

/// Type de message échangé entre l'iPhone et le Mac.
public enum PortalKind: String, Codable, Sendable {
    case file            // fichier, photo ou vidéo (payload = contenu)
    case clipboardText   // texte du presse-papiers (payload = UTF-8)
    case clipboardImage  // image du presse-papiers (payload = PNG/JPEG)
    case ack             // accusé de réception du Mac (pas de payload)
}

/// En-tête JSON qui précède chaque payload.
public struct PortalHeader: Codable, Equatable, Sendable {
    public var kind: PortalKind
    public var name: String?
    public var size: Int64
    public var uti: String?
    /// Animation d'arrivée choisie sur l'iPhone.
    public var transition: String?
    /// Nom de l'appareil qui envoie.
    public var sender: String?
    /// Pour un ack : le nom final du fichier côté Mac, ou une erreur.
    public var result: String?

    public init(kind: PortalKind, name: String? = nil, size: Int64 = 0, uti: String? = nil,
                transition: String? = nil, sender: String? = nil, result: String? = nil) {
        self.kind = kind
        self.name = name
        self.size = size
        self.uti = uti
        self.transition = transition
        self.sender = sender
        self.result = result
    }
}

/// Trame : 4 octets (longueur de l'en-tête, big-endian) + en-tête JSON + `size` octets de payload.
public enum PortalFraming {
    public static let maxHeaderSize = 64 * 1024

    public static func encode(_ header: PortalHeader) -> Data {
        let json = (try? JSONEncoder().encode(header)) ?? Data()
        var length = UInt32(json.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(json)
        return data
    }
}

/// Décodage en flux : on lui donne les octets au fil de l'eau, il rend en-têtes, morceaux de payload et fins.
public struct PortalDecoder: Sendable {
    public enum Event: Equatable, Sendable {
        case header(PortalHeader)
        case chunk(Data)
        case end
    }

    public enum DecodeError: Error, Equatable { case headerTooLarge, badHeader }

    private var buffer = Data()
    private var remaining: Int64 = 0
    private var inPayload = false

    public init() {}

    public mutating func feed(_ data: Data) throws -> [Event] {
        buffer.append(data)
        var events: [Event] = []
        while true {
            if inPayload {
                if remaining == 0 {
                    inPayload = false
                    events.append(.end)
                    continue
                }
                guard !buffer.isEmpty else { break }
                let take = Int(min(Int64(buffer.count), remaining))
                events.append(.chunk(buffer.prefix(take)))
                buffer.removeFirst(take)
                remaining -= Int64(take)
                continue
            }
            guard buffer.count >= 4 else { break }
            let len = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard len <= PortalFraming.maxHeaderSize else { throw DecodeError.headerTooLarge }
            guard buffer.count >= 4 + len else { break }
            let json = buffer.dropFirst(4).prefix(len)
            guard let header = try? JSONDecoder().decode(PortalHeader.self, from: Data(json)) else {
                throw DecodeError.badHeader
            }
            buffer.removeFirst(4 + len)
            events.append(.header(header))
            remaining = max(header.size, 0)
            inPayload = true
        }
        // Évite que `buffer` garde un gros stockage après removeFirst.
        if buffer.isEmpty { buffer = Data() }
        return events
    }
}

/// Informations d'appairage contenues dans le QR code affiché par le Mac.
public struct PortalPairing: Equatable, Sendable {
    public static let scheme = "islandportal"
    public static let serviceType = "_islandportal._tcp"

    /// Secret partagé (32 octets) servant de clé TLS-PSK.
    public var key: Data
    /// Nom Bonjour du Mac.
    public var macName: String

    public init(key: Data, macName: String) {
        self.key = key
        self.macName = macName
    }

    public static func generate(macName: String) -> PortalPairing {
        PortalPairing(key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, macName: macName)
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "k", value: key.base64URLEncoded),
            URLQueryItem(name: "n", value: macName),
        ]
        return c.url!
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let k = items.first(where: { $0.name == "k" })?.value, let key = Data(base64URLEncoded: k), key.count == 32,
              let name = items.first(where: { $0.name == "n" })?.value, !name.isEmpty else { return nil }
        self.init(key: key, macName: name)
    }

    /// Empreinte courte et lisible, affichée des deux côtés pour vérifier qu'on parle au bon appareil.
    public var fingerprint: String {
        SHA256.hash(data: key).prefix(3).map { String(format: "%02X", $0) }.joined(separator: "-")
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}

/// Nom de fichier sûr : pas de chemin, pas de caractères spéciaux, jamais vide.
public enum PortalFileNames {
    public static func sanitize(_ name: String?) -> String {
        let base = (name ?? "").components(separatedBy: CharacterSet(charactersIn: "/\\:")).last ?? ""
        let cleaned = base.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        var s = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "Fichier Portal" }
        return String(s.prefix(200))
    }

    /// `photo.jpg` -> `photo 2.jpg`, `photo 3.jpg`… si le nom est déjà pris dans `directory`.
    public static func unique(_ name: String, in directory: URL, fileManager: FileManager = .default) -> URL {
        var url = directory.appendingPathComponent(name)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        while fileManager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return url
    }
}
