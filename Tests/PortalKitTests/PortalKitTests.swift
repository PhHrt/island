import Foundation
import Testing
@testable import PortalKit

@Suite("Protocole Portal")
struct PortalProtocolTests {
    @Test func framingRoundTripInPieces() throws {
        let h1 = PortalHeader(kind: .file, name: "photo.jpg", size: 5, uti: "public.jpeg", transition: "plane", sender: "iPhone")
        let h2 = PortalHeader(kind: .clipboardText, size: 3)
        var stream = PortalFraming.encode(h1) + Data("hello".utf8) + PortalFraming.encode(h2) + Data("abc".utf8)
        // Livré octet par octet : le décodeur doit reconstituer les mêmes événements.
        var decoder = PortalDecoder()
        var events: [PortalDecoder.Event] = []
        while !stream.isEmpty {
            events += try decoder.feed(stream.prefix(1))
            stream.removeFirst()
        }
        let headers = events.compactMap { if case .header(let h) = $0 { h } else { nil } }
        let payload = events.compactMap { if case .chunk(let d) = $0 { d } else { nil } }.reduce(Data(), +)
        #expect(headers == [h1, h2])
        #expect(String(decoding: payload, as: UTF8.self) == "helloabc")
        #expect(events.filter { $0 == .end }.count == 2)
    }

    @Test func emptyPayloadEndsImmediately() throws {
        var d = PortalDecoder()
        let events = try d.feed(PortalFraming.encode(PortalHeader(kind: .ack, result: "ok")))
        #expect(events.count == 2)
        #expect(events.last == .end)
    }

    @Test func rejectsHugeHeader() {
        var d = PortalDecoder()
        #expect(throws: PortalDecoder.DecodeError.headerTooLarge) {
            _ = try d.feed(Data([0x7F, 0xFF, 0xFF, 0xFF]))
        }
    }

    @Test func pairingURLRoundTrip() {
        let p = PortalPairing.generate(macName: "MacBook de Paul")
        #expect(p.key.count == 32)
        let back = PortalPairing(url: p.url)
        #expect(back == p)
        #expect(p.fingerprint.count == 8)
        #expect(PortalPairing(url: URL(string: "islandportal://pair?k=abc&n=x")!) == nil)
        #expect(PortalPairing(url: URL(string: "https://example.com")!) == nil)
    }

    @Test func sanitizesFileNames() {
        #expect(PortalFileNames.sanitize("../../etc/passwd") == "passwd")
        #expect(PortalFileNames.sanitize(".hidden") == "hidden")
        #expect(PortalFileNames.sanitize(nil) == "Fichier Portal")
        #expect(PortalFileNames.sanitize("a\u{0}b.txt") == "ab.txt")
    }

    @Test func uniqueNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.txt").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a 2.txt").path, contents: Data())
        #expect(PortalFileNames.unique("a.txt", in: dir).lastPathComponent == "a 3.txt")
        #expect(PortalFileNames.unique("b.txt", in: dir).lastPathComponent == "b.txt")
    }
}

/// Vrai transfert TLS-PSK en boucle locale : serveur et client dans le même processus.
@Suite("Transfert Portal (boucle locale)", .serialized)
struct PortalLoopbackTests {
    final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [PortalReceived] = []
        func add(_ r: PortalReceived) { lock.lock(); items.append(r); lock.unlock() }
        var all: [PortalReceived] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func makeServer(key: Data, dir: URL, inbox: Inbox) async throws -> PortalServer {
        let server = PortalServer(key: key, serviceName: nil, destination: dir)
        server.onReceive = { inbox.add($0) }
        try await server.start()
        return server
    }

    @Test func sendsFileAndClipboard() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = PortalPairing.generate(macName: "test").key
        let inbox = Inbox()
        let server = try await makeServer(key: key, dir: dir, inbox: inbox)
        defer { server.stop() }

        // Fichier de 3 Mo aléatoire.
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString).bin")
        let bytes = Data((0..<(3 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255) })
        try bytes.write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let client = PortalClient(host: "127.0.0.1", port: try #require(server.port), key: key, senderName: "test")
        try await client.connect()
        let progress = Inbox()
        let savedName = try await client.sendFile(src, name: "vidéo test.bin", transition: "slide") { f in
            if f >= 1 { progress.add(.text("done", header: PortalHeader(kind: .ack))) }
        }
        try await client.sendText("Bonjour depuis l'iPhone 👋")
        client.close()

        #expect(savedName == "vidéo test.bin")
        #expect(progress.all.count == 1)
        let received = try Data(contentsOf: dir.appendingPathComponent("vidéo test.bin"))
        #expect(received == bytes)
        // Pas de fichier partiel qui traîne.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".partial") }
        #expect(leftovers.isEmpty)

        let texts = inbox.all.compactMap { if case .text(let t, _) = $0 { t } else { nil } }
        #expect(texts == ["Bonjour depuis l'iPhone 👋"])
        let files = inbox.all.compactMap { if case .file(_, let h) = $0 { h.transition } else { nil } }
        #expect(files == ["slide"])
    }

    @Test func wrongKeyIsRefused() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = Inbox()
        let server = try await makeServer(key: PortalPairing.generate(macName: "a").key, dir: dir, inbox: inbox)
        defer { server.stop() }

        let intruder = PortalClient(host: "127.0.0.1", port: try #require(server.port),
                                    key: PortalPairing.generate(macName: "b").key, senderName: "intrus")
        await #expect(throws: (any Error).self) {
            try await intruder.connect()
            try await intruder.sendText("ne doit pas arriver")
        }
        intruder.close()
        #expect(inbox.all.isEmpty)
    }
}
