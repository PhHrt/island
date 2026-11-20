import CryptoKit
import Foundation
import Network
import Security

/// TCP + TLS 1.2 avec clé pré-partagée (PSK) : seul un appareil qui a scanné le QR code peut se connecter,
/// et tout le trafic est chiffré. Même schéma que l'exemple TicTacToe d'Apple.
public enum PortalTLS {
    static let identity = "island-portal"

    public static func parameters(key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        // On dérive la clé TLS du secret plutôt que d'utiliser le secret brut.
        var code = HMAC<SHA256>.authenticationCode(for: Data(identity.utf8), using: SymmetricKey(data: key))
        let keyData = withUnsafeBytes(of: &code) { DispatchData(bytes: $0) }
        let idData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, keyData as __DispatchData, idData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.connectionTimeout = 8
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }
}

/// Ce que le Mac a reçu.
public enum PortalReceived: Sendable {
    case file(URL, header: PortalHeader)
    case text(String, header: PortalHeader)
    case image(Data, header: PortalHeader)
}

// MARK: - Serveur (Mac)

/// Écoute les connexions Portal, annonce le Mac en Bonjour et range les fichiers reçus.
public final class PortalServer: @unchecked Sendable {
    public var onReceive: (@Sendable (PortalReceived) -> Void)?
    /// (nom, octets reçus, taille totale)
    public var onProgress: (@Sendable (String, Int64, Int64) -> Void)?
    public var onStateChange: (@Sendable (String) -> Void)?

    private let key: Data
    private let serviceName: String?
    private let destination: URL
    private let requestedPort: NWEndpoint.Port
    private let queue = DispatchQueue(label: "dev.island.portal.server")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: ServerSession] = [:]

    /// - Parameters:
    ///   - serviceName: nom Bonjour ; nil = pas d'annonce (tests).
    ///   - destination: dossier où ranger les fichiers.
    public init(key: Data, serviceName: String?, destination: URL, port: NWEndpoint.Port = .any) {
        self.key = key
        self.serviceName = serviceName
        self.destination = destination
        self.requestedPort = port
    }

    /// Port effectif une fois prêt.
    public private(set) var port: UInt16?

    public func start() async throws {
        let listener = try NWListener(using: PortalTLS.parameters(key: key), on: requestedPort)
        if let serviceName {
            listener.service = NWListener.Service(name: serviceName, type: PortalPairing.serviceType)
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                self?.onStateChange?("\(state)")
                switch state {
                case .ready:
                    self?.port = listener.port?.rawValue
                    if !resumed { resumed = true; cont.resume() }
                case .failed(let error):
                    if !resumed { resumed = true; cont.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            self?.sessions.values.forEach { $0.cancel() }
            self?.sessions.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        let session = ServerSession(connection: connection, destination: destination, queue: queue)
        let id = ObjectIdentifier(session)
        session.onReceive = { [weak self] in self?.onReceive?($0) }
        session.onProgress = { [weak self] in self?.onProgress?($0, $1, $2) }
        session.onClose = { [weak self] in self?.sessions[id] = nil }
        sessions[id] = session
        session.start()
    }
}

/// Une connexion entrante : décode les trames, écrit les fichiers en flux, renvoie un ack par message.
final class ServerSession: @unchecked Sendable {
    var onReceive: ((PortalReceived) -> Void)?
    var onProgress: ((String, Int64, Int64) -> Void)?
    var onClose: (() -> Void)?

    private let connection: NWConnection
    private let destination: URL
    private let queue: DispatchQueue
    private var decoder = PortalDecoder()

    private var header: PortalHeader?
    private var received: Int64 = 0
    private var fileHandle: FileHandle?
    private var partialURL: URL?
    private var memory = Data()
    private static let maxInMemory: Int64 = 20 * 1024 * 1024

    init(connection: NWConnection, destination: URL, queue: DispatchQueue) {
        self.connection = connection
        self.destination = destination
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for event in try self.decoder.feed(data) { try self.handle(event) }
                } catch {
                    self.connection.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                self.connection.cancel()
            } else {
                self.receive()
            }
        }
    }

    private func handle(_ event: PortalDecoder.Event) throws {
        switch event {
        case .header(let h):
            header = h
            received = 0
            memory = Data()
            if h.kind == .file {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let partial = destination.appendingPathComponent(".portal-\(UUID().uuidString).partial")
                FileManager.default.createFile(atPath: partial.path, contents: nil)
                partialURL = partial
                fileHandle = try FileHandle(forWritingTo: partial)
            } else if h.size > Self.maxInMemory {
                throw PortalDecoder.DecodeError.headerTooLarge
            }
        case .chunk(let data):
            guard let h = header else { return }
            received += Int64(data.count)
            if h.kind == .file { try fileHandle?.write(contentsOf: data) } else { memory.append(data) }
            onProgress?(h.name ?? "", received, h.size)
        case .end:
            guard let h = header else { return }
            header = nil
            var result = "ok"
            switch h.kind {
            case .file:
                try fileHandle?.close()
                fileHandle = nil
                if let partial = partialURL {
                    let final = PortalFileNames.unique(PortalFileNames.sanitize(h.name), in: destination)
                    try FileManager.default.moveItem(at: partial, to: final)
                    partialURL = nil
                    result = final.lastPathComponent
                    onReceive?(.file(final, header: h))
                }
            case .clipboardText:
                onReceive?(.text(String(decoding: memory, as: UTF8.self), header: h))
            case .clipboardImage:
                onReceive?(.image(memory, header: h))
            case .ack:
                break
            }
            memory = Data()
            connection.send(content: PortalFraming.encode(PortalHeader(kind: .ack, name: h.name, result: result)),
                            completion: .contentProcessed { _ in })
        }
    }

    private func finish() {
        // Un transfert interrompu ne laisse pas de fichier partiel.
        try? fileHandle?.close()
        fileHandle = nil
        if let partial = partialURL { try? FileManager.default.removeItem(at: partial) }
        partialURL = nil
        onClose?()
        onClose = nil
    }
}

// MARK: - Client (iPhone, ou outil portal-send)

public enum PortalClientError: Error, LocalizedError {
    case connectionFailed(String)
    case closed
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let m): "Connexion impossible : \(m)"
        case .closed: "Connexion fermée par le Mac"
        case .rejected(let m): "Refusé par le Mac : \(m)"
        }
    }
}

/// Connexion vers le Mac ; envoie des fichiers (en flux) ou le presse-papiers et attend l'accusé de réception.
public final class PortalClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.island.portal.client")
    private var decoder = PortalDecoder()
    public let senderName: String

    public init(endpoint: NWEndpoint, key: Data, senderName: String) {
        connection = NWConnection(to: endpoint, using: PortalTLS.parameters(key: key))
        self.senderName = senderName
    }

    public convenience init(host: String, port: UInt16, key: Data, senderName: String) {
        self.init(endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!),
                  key: key, senderName: senderName)
    }

    public func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; cont.resume() }
                case .failed(let e):
                    if !resumed { resumed = true; cont.resume(throwing: PortalClientError.connectionFailed("\(e)")) }
                case .waiting(let e):
                    // Mauvaise clé ou Mac injoignable : on n'attend pas indéfiniment.
                    if !resumed { resumed = true; cont.resume(throwing: PortalClientError.connectionFailed("\(e)")) }
                case .cancelled:
                    if !resumed { resumed = true; cont.resume(throwing: PortalClientError.closed) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func close() { connection.cancel() }

    /// Envoie un fichier par morceaux de 256 Ko. `progress` reçoit une fraction de 0 à 1.
    @discardableResult
    public func sendFile(_ url: URL, name: String? = nil, uti: String? = nil, transition: String? = nil,
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let header = PortalHeader(kind: .file, name: name ?? url.lastPathComponent, size: size, uti: uti,
                                  transition: transition, sender: senderName)
        try await send(PortalFraming.encode(header))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sent: Int64 = 0
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try await send(chunk)
            sent += Int64(chunk.count)
            progress?(size > 0 ? Double(sent) / Double(size) : 1)
        }
        return try await waitForAck()
    }

    public func sendText(_ text: String, transition: String? = nil) async throws {
        let data = Data(text.utf8)
        try await send(PortalFraming.encode(PortalHeader(kind: .clipboardText, size: Int64(data.count),
                                                         transition: transition, sender: senderName)) + data)
        _ = try await waitForAck()
    }

    public func sendImage(_ data: Data, uti: String, transition: String? = nil) async throws {
        try await send(PortalFraming.encode(PortalHeader(kind: .clipboardImage, size: Int64(data.count), uti: uti,
                                                         transition: transition, sender: senderName)) + data)
        _ = try await waitForAck()
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: PortalClientError.connectionFailed("\(error)")) } else { cont.resume() }
            })
        }
    }

    private func waitForAck() async throws -> String {
        while true {
            let data: Data = try await withCheckedThrowingContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let data, !data.isEmpty { cont.resume(returning: data) }
                    else if let error { cont.resume(throwing: PortalClientError.connectionFailed("\(error)")) }
                    else if isComplete { cont.resume(throwing: PortalClientError.closed) }
                    else { cont.resume(returning: Data()) }
                }
            }
            for event in try decoder.feed(data) {
                if case .header(let h) = event, h.kind == .ack {
                    let result = h.result ?? "ok"
                    if result.hasPrefix("error") { throw PortalClientError.rejected(result) }
                    return result
                }
            }
        }
    }
}

// MARK: - Découverte Bonjour (iPhone)

/// Cherche les Mac qui annoncent Portal sur le réseau local.
public final class PortalBrowser: @unchecked Sendable {
    public struct Found: Hashable, Sendable {
        public let name: String
        public let endpoint: NWEndpoint
    }

    public var onChange: (@Sendable ([Found]) -> Void)?
    private var browser: NWBrowser?

    public init() {}

    public func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: PortalPairing.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> Found? in
                if case .service(let name, _, _, _) = r.endpoint { return Found(name: name, endpoint: r.endpoint) }
                return nil
            }
            self?.onChange?(found)
        }
        b.start(queue: .main)
        browser = b
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}
