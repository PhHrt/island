import CryptoKit
import Foundation
import IslandCore

/// Récupère les paroles du morceau en cours sur LRCLib, avec un cache disque (y compris « introuvable »).
/// Seuls le titre, l'artiste, l'album et la durée partent sur le réseau ; rien si les paroles sont désactivées.
@MainActor
final class LyricsProvider {
    private let model: IslandModel
    private var currentKey: String?
    private var task: Task<Void, Never>?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.httpAdditionalHeaders = ["User-Agent": "Island/0.1 (https://github.com/PhHrt/island)"]
        return URLSession(configuration: c)
    }()

    init(model: IslandModel) { self.model = model }

    /// Appelé à chaque message Now Playing ; ne fait quelque chose que si le morceau a changé.
    func trackChanged(_ np: NowPlaying?) {
        guard Prefs.lyrics, let np, !np.title.isEmpty else {
            currentKey = nil
            task?.cancel()
            if model.lyrics != nil { model.lyrics = nil }
            return
        }
        let key = "\(np.artist)|\(np.title)|\(Int(np.duration.rounded()))"
        guard key != currentKey else { return }
        currentKey = key
        model.lyrics = nil
        task?.cancel()

        let query = LyricsQuery(title: np.title, artist: np.artist, album: np.album, duration: np.duration)
        task = Task { [weak self] in
            guard let self else { return }
            let lyrics = await self.load(query, key: key)
            guard !Task.isCancelled, self.currentKey == key else { return }
            self.model.lyrics = lyrics
        }
    }

    // MARK: Cache + réseau

    private static let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.island.app/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func cacheURL(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return Self.cacheDir.appendingPathComponent("\(hash).json")
    }

    private func load(_ q: LyricsQuery, key: String) async -> Lyrics? {
        let file = cacheURL(key)
        if let data = try? Data(contentsOf: file) {
            if data == Data("null".utf8) { return nil }
            if let record = try? JSONDecoder().decode(LRCLibRecord.self, from: data) { return record.lyrics }
        }
        let record = await fetch(q)
        // Une erreur réseau n'est pas mise en cache (on réessaiera au prochain passage du morceau).
        switch record {
        case .found(let r):
            try? JSONEncoder().encode(r).write(to: file)
            return r.lyrics
        case .notFound:
            try? Data("null".utf8).write(to: file)
            return nil
        case .failed:
            if currentKey == key { currentKey = nil }
            return nil
        }
    }

    private enum FetchResult { case found(LRCLibRecord), notFound, failed }

    private func fetch(_ q: LyricsQuery) async -> FetchResult {
        do {
            let (data, response) = try await session.data(from: q.getURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let r = try? JSONDecoder().decode(LRCLibRecord.self, from: data), r.lyrics != nil {
                return .found(r)
            }
            guard status == 200 || status == 404 else { return .failed }

            let (sdata, sresp) = try await session.data(from: q.searchURL)
            guard (sresp as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
            let results = (try? JSONDecoder().decode([LRCLibRecord].self, from: sdata)) ?? []
            if let best = LRCLibRecord.bestMatch(results, duration: q.duration > 0 ? q.duration : nil) {
                return .found(best)
            }
            return .notFound
        } catch {
            return .failed
        }
    }
}
