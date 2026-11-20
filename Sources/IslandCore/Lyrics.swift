import Foundation

/// Un mot horodaté (format LRC « enhanced » : `<mm:ss.xx>mot`).
public struct LyricWord: Equatable, Sendable {
    public var time: Double
    public var text: String
}

public struct LyricLine: Equatable, Sendable {
    public var time: Double
    public var text: String
    /// Timings mot à mot quand la source les fournit, sinon nil.
    public var words: [LyricWord]?
}

public struct Lyrics: Equatable, Sendable {
    public var lines: [LyricLine]
    public var isSynced: Bool
    public var isInstrumental: Bool

    public init(lines: [LyricLine], isSynced: Bool, isInstrumental: Bool = false) {
        self.lines = lines
        self.isSynced = isSynced
        self.isInstrumental = isInstrumental
    }

    /// Index de la ligne en cours à la position `time`, ou nil avant la première ligne.
    public func lineIndex(at time: Double) -> Int? {
        guard isSynced, let first = lines.first, time >= first.time else { return nil }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].time <= time { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Avancement (0…1) dans la ligne `index`, pour un surlignage progressif.
    public func progress(inLine index: Int, at time: Double, trackDuration: Double) -> Double {
        let start = lines[index].time
        let end = index + 1 < lines.count ? lines[index + 1].time : max(trackDuration, start + 4)
        guard end > start else { return 1 }
        return min(max((time - start) / (end - start), 0), 1)
    }
}

public enum LRCParser {
    /// Analyse un texte LRC. Gère plusieurs horodatages par ligne, l'offset `[offset:±ms]`,
    /// les balises mot à mot, et ignore les métadonnées (`[ar:…]`, `[ti:…]`).
    public static func parse(_ text: String) -> Lyrics {
        var offset = 0.0
        var lines: [LyricLine] = []

        for raw in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw).trimmingCharacters(in: .whitespaces)[...]
            var times: [Double] = []

            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let t = parseTimestamp(tag) {
                    times.append(t)
                } else if tag.lowercased().hasPrefix("offset:"), let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = ms / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            guard !times.isEmpty else { continue }

            let (plain, words) = parseWords(String(rest))
            for t in times {
                lines.append(LyricLine(time: t, text: plain, words: words))
            }
        }

        // L'offset LRC positif avance les paroles (elles s'affichent plus tôt).
        let shifted = lines
            .map { line -> LyricLine in
                var l = line
                l.time = max(0, l.time - offset)
                l.words = l.words?.map { LyricWord(time: max(0, $0.time - offset), text: $0.text) }
                return l
            }
            .sorted { $0.time < $1.time }
        return Lyrics(lines: shifted, isSynced: !shifted.isEmpty)
    }

    /// Paroles non synchronisées : une ligne par ligne de texte, sans horodatage.
    public static func plain(_ text: String) -> Lyrics {
        let lines = text.split(whereSeparator: \.isNewline).map {
            LyricLine(time: 0, text: $0.trimmingCharacters(in: .whitespaces), words: nil)
        }
        return Lyrics(lines: lines, isSynced: false)
    }

    /// `mm:ss`, `mm:ss.x`, `mm:ss.xx`, `mm:ss.xxx` (et `:` à la place du point).
    static func parseTimestamp<S: StringProtocol>(_ s: S) -> Double? {
        let parts = s.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let min = Int(parts[0]), min >= 0 else { return nil }
        let secPart = parts[1].replacingOccurrences(of: ":", with: ".")
        guard let sec = Double(secPart), sec >= 0, sec < 60 else { return nil }
        return Double(min) * 60 + sec
    }

    static func parseWords(_ s: String) -> (String, [LyricWord]?) {
        guard s.contains("<") else { return (s.trimmingCharacters(in: .whitespaces), nil) }
        var words: [LyricWord] = []
        var plain = ""
        var rest = s[...]
        var current: Double?
        while !rest.isEmpty {
            if rest.hasPrefix("<"), let close = rest.firstIndex(of: ">"),
               let t = parseTimestamp(rest[rest.index(after: rest.startIndex)..<close]) {
                current = t
                rest = rest[rest.index(after: close)...]
                continue
            }
            let next = rest.firstIndex(of: "<") ?? rest.endIndex
            let chunk = String(rest[..<next])
            plain += chunk
            if let t = current, !chunk.trimmingCharacters(in: .whitespaces).isEmpty {
                words.append(LyricWord(time: t, text: chunk))
            }
            current = nil
            rest = rest[next...]
            if next < s.endIndex, rest.hasPrefix("<"), rest.firstIndex(of: ">") == nil { break }
        }
        let trimmed = plain.trimmingCharacters(in: .whitespaces)
        return (trimmed, words.isEmpty ? nil : words)
    }
}

/// Réponse de l'API LRCLib (`/api/get` et éléments de `/api/search`).
public struct LRCLibRecord: Codable, Equatable, Sendable {
    public var id: Int?
    public var trackName: String?
    public var artistName: String?
    public var albumName: String?
    public var duration: Double?
    public var instrumental: Bool?
    public var plainLyrics: String?
    public var syncedLyrics: String?

    public var lyrics: Lyrics? {
        if instrumental == true { return Lyrics(lines: [], isSynced: false, isInstrumental: true) }
        if let s = syncedLyrics, !s.isEmpty {
            let parsed = LRCParser.parse(s)
            if !parsed.lines.isEmpty { return parsed }
        }
        if let p = plainLyrics, !p.isEmpty { return LRCParser.plain(p) }
        return nil
    }

    /// Choisit le meilleur résultat d'une recherche : paroles synchronisées d'abord,
    /// durée la plus proche (à ±4 s près quand la durée est connue).
    public static func bestMatch(_ records: [LRCLibRecord], duration: Double?) -> LRCLibRecord? {
        let usable = records.filter { $0.lyrics != nil }
        let filtered: [LRCLibRecord]
        if let d = duration, d > 0 {
            filtered = usable.filter { abs(($0.duration ?? d) - d) <= 4 }
        } else {
            filtered = usable
        }
        return filtered.min { a, b in
            let sa = (a.syncedLyrics?.isEmpty == false) ? 0 : 1
            let sb = (b.syncedLyrics?.isEmpty == false) ? 0 : 1
            if sa != sb { return sa < sb }
            let da = abs((a.duration ?? 0) - (duration ?? 0))
            let db = abs((b.duration ?? 0) - (duration ?? 0))
            return da < db
        }
    }
}

/// Requête LRCLib pour un morceau : `/api/get` exact, puis `/api/search` avec un titre nettoyé.
public struct LyricsQuery: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double

    public init(title: String, artist: String, album: String, duration: Double) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    public var getURL: URL {
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        c.queryItems = items
        return c.url!
    }

    public var searchURL: URL {
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [URLQueryItem(name: "track_name", value: Self.cleanTitle(title)),
                        URLQueryItem(name: "artist_name", value: artist)]
        return c.url!
    }

    /// Retire les mentions qui empêchent la correspondance : « (Remastered 2011) », « - Live », « [Official Video] »…
    public static func cleanTitle(_ title: String) -> String {
        var t = title
        let noise = ["remaster", "live", "version", "edit", "mono", "stereo", "official", "video", "audio",
                     "lyrics", "explicit", "feat", "ft."]
        // Parenthèses et crochets contenant du bruit
        for (open, close) in [("(", ")"), ("[", "]")] {
            while let o = t.range(of: open), let c = t.range(of: close, range: o.upperBound..<t.endIndex) {
                let inside = t[o.upperBound..<c.lowerBound].lowercased()
                guard noise.contains(where: { inside.contains($0) }) else { break }
                t.removeSubrange(o.lowerBound..<c.upperBound)
            }
        }
        // Suffixe « - … Remaster »
        if let dash = t.range(of: " - ", options: .backwards) {
            let suffix = t[dash.upperBound...].lowercased()
            if noise.contains(where: { suffix.contains($0) }) { t = String(t[..<dash.lowerBound]) }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
