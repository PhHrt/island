import AppKit
import Foundation
import SwiftUI

/// Lance le helper MediaRemote dans /usr/bin/perl, lit son flux JSON et lui envoie les commandes.
/// Si le helper meurt, il est relancé au bout de 2 s.
@MainActor
final class NowPlayingProvider {
    private let model: IslandModel
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var stopped = false
    private var lastArtworkPath: String?
    private var lastArtwork: NSImage?
    private var lastAccent = Color.white
    /// Appelé après chaque message (nil = plus rien en lecture) ; sert au provider de paroles.
    var onChange: ((NowPlaying?) -> Void)?

    init(model: IslandModel) {
        self.model = model
        model.sendCommand = { [weak self] cmd in self?.send(cmd.rawValue) }
        model.seek = { [weak self] seconds in self?.seek(to: seconds) }
    }

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    func seek(to seconds: Double) {
        send(String(format: "seek %.3f", seconds))
    }

    private func send(_ line: String) {
        guard let input else { return }
        try? input.write(contentsOf: Data((line + "\n").utf8))
    }

    private static var helperDir: URL? {
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("nowplaying"),
           FileManager.default.fileExists(atPath: dir.appendingPathComponent("mr_helper.dylib").path) {
            return dir
        }
        return nil
    }

    private static var artworkDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.island.app/artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func launch() {
        guard let dir = Self.helperDir else {
            NSLog("Island: helper Now Playing introuvable dans le bundle")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [dir.appendingPathComponent("run.pl").path, dir.appendingPathComponent("mr_helper.dylib").path]
        var env = ProcessInfo.processInfo.environment
        env["ISLAND_ART_DIR"] = Self.artworkDir.path
        p.environment = env

        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.receive(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.process = nil
                self.input = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.launch() }
            }
        }
        do {
            try p.run()
            process = p
            input = inp.fileHandleForWriting
        } catch {
            NSLog("Island: lancement du helper impossible: \(error)")
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let msg = try? JSONDecoder().decode(NowPlayingMessage.self, from: line) {
                apply(msg)
            }
        }
    }

    private func apply(_ msg: NowPlayingMessage) {
        if msg.error != nil { return }
        guard msg.empty != true, let title = msg.title, !title.isEmpty else {
            if model.nowPlaying != nil { model.nowPlaying = nil }
            onChange?(nil)
            return
        }

        // La pochette n'est pas dans tous les messages : on garde la dernière tant que le titre ne change pas.
        let sameTrack = model.nowPlaying?.title == title && model.nowPlaying?.artist == (msg.artist ?? "")
        if let path = msg.artwork, path != lastArtworkPath || !sameTrack {
            if let img = NSImage(contentsOfFile: path) {
                lastArtwork = img
                lastAccent = Artwork.accent(of: img)
                lastArtworkPath = path
            }
        } else if msg.artwork == nil && !sameTrack {
            lastArtwork = nil
            lastArtworkPath = nil
            lastAccent = .white
        }

        var app: NSRunningApplication?
        if let pid = msg.pid, pid > 0 { app = NSRunningApplication(processIdentifier: pid) }

        let rate = msg.rate ?? 0
        let next = NowPlaying(
            title: title,
            artist: msg.artist ?? "",
            album: msg.album ?? "",
            duration: msg.duration ?? 0,
            elapsed: msg.elapsed ?? 0,
            timestamp: msg.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date(),
            rate: rate,
            isPlaying: (msg.playing ?? false) && rate > 0,
            bundleID: app?.bundleIdentifier,
            appName: app?.localizedName,
            artwork: lastArtwork,
            artworkPath: lastArtworkPath,
            accent: lastAccent
        )
        if next != model.nowPlaying { model.nowPlaying = next }
        onChange?(next)
    }
}
