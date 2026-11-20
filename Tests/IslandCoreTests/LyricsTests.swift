import Foundation
import Testing
@testable import IslandCore

@Suite("Paroles LRC")
struct LyricsTests {
    @Test func parsesBasicLines() {
        let lrc = """
        [ar:Artiste]
        [ti:Titre]
        [00:12.00]Première ligne
        [00:15.50]Deuxième ligne
        [01:02.345]Troisième
        """
        let l = LRCParser.parse(lrc)
        #expect(l.isSynced)
        #expect(l.lines.map(\.text) == ["Première ligne", "Deuxième ligne", "Troisième"])
        #expect(l.lines.map(\.time) == [12, 15.5, 62.345])
    }

    @Test func multipleTimestampsOnOneLineAreSorted() {
        let l = LRCParser.parse("[00:30.00][00:10.00]Refrain\n[00:20.00]Couplet")
        #expect(l.lines.map(\.text) == ["Refrain", "Couplet", "Refrain"])
        #expect(l.lines.map(\.time) == [10, 20, 30])
    }

    @Test func appliesOffset() {
        let l = LRCParser.parse("[offset:+500]\n[00:10.00]A")
        #expect(l.lines.first?.time == 9.5)
    }

    @Test func parsesEnhancedWordTimings() {
        let l = LRCParser.parse("[00:01.00]<00:01.00>Hello <00:01.50>world")
        #expect(l.lines.first?.text == "Hello world")
        #expect(l.lines.first?.words?.map(\.time) == [1.0, 1.5])
        #expect(l.lines.first?.words?.map { $0.text.trimmingCharacters(in: .whitespaces) } == ["Hello", "world"])
    }

    @Test func ignoresGarbage() {
        let l = LRCParser.parse("pas de tag\n[xx:yy]rien\n[00:61.00]secondes invalides")
        #expect(l.lines.isEmpty)
        #expect(!l.isSynced)
    }

    @Test func lineIndexLookup() {
        let l = LRCParser.parse("[00:10.00]A\n[00:20.00]B\n[00:30.00]C")
        #expect(l.lineIndex(at: 5) == nil)
        #expect(l.lineIndex(at: 10) == 0)
        #expect(l.lineIndex(at: 19.99) == 0)
        #expect(l.lineIndex(at: 20) == 1)
        #expect(l.lineIndex(at: 500) == 2)
        #expect(l.progress(inLine: 0, at: 15, trackDuration: 60) == 0.5)
    }

    @Test func plainLyricsAreNotSynced() {
        let l = LRCParser.plain("Ligne 1\nLigne 2")
        #expect(!l.isSynced)
        #expect(l.lineIndex(at: 10) == nil)
        #expect(l.lines.count == 2)
    }

    @Test func decodesLRCLibAndPrefersSynced() throws {
        let json = """
        [{"id":1,"trackName":"T","artistName":"A","duration":200,"instrumental":false,"plainLyrics":"x","syncedLyrics":null},
         {"id":2,"trackName":"T","artistName":"A","duration":201,"instrumental":false,"plainLyrics":"x","syncedLyrics":"[00:01.00]x"},
         {"id":3,"trackName":"T","artistName":"A","duration":260,"instrumental":false,"plainLyrics":"x","syncedLyrics":"[00:01.00]x"}]
        """
        let records = try JSONDecoder().decode([LRCLibRecord].self, from: Data(json.utf8))
        #expect(LRCLibRecord.bestMatch(records, duration: 200)?.id == 2)
        #expect(LRCLibRecord.bestMatch(records, duration: 500) == nil)
    }

    @Test func instrumentalRecord() {
        let r = LRCLibRecord(id: 1, instrumental: true)
        #expect(r.lyrics?.isInstrumental == true)
    }
}

@Suite("Requêtes LRCLib")
struct LyricsQueryTests {
    @Test func cleansTitles() {
        #expect(LyricsQuery.cleanTitle("Let It Be (Remastered 2009)") == "Let It Be")
        #expect(LyricsQuery.cleanTitle("Song - 2011 Remaster") == "Song")
        #expect(LyricsQuery.cleanTitle("Song [Official Video]") == "Song")
        #expect(LyricsQuery.cleanTitle("She's Gone") == "She's Gone")
        #expect(LyricsQuery.cleanTitle("Love (Intro)") == "Love (Intro)")
    }

    @Test func buildsGetURL() {
        let q = LyricsQuery(title: "She's Gone", artist: "Steelheart", album: "", duration: 391.6)
        let url = q.getURL.absoluteString
        #expect(url.contains("track_name=She's%20Gone"))
        #expect(url.contains("duration=392"))
        #expect(!url.contains("album_name"))
    }
}

@Suite("Mot à mot")
struct TimedWordsTests {
    @Test func usesRealWordTimings() {
        let l = LRCParser.parse("[00:01.00]<00:01.00>Hello <00:01.50>world\n[00:03.00]Next")
        let w = l.timedWords(inLine: 0, trackDuration: 60)
        #expect(w.map(\.text) == ["Hello", "world"])
        #expect(w.map(\.start) == [1.0, 1.5])
        #expect(w.last?.end == 3.0)
    }

    @Test func distributesByLetterCount() {
        let l = LRCParser.parse("[00:10.00]ab abcd\n[00:13.00]x")
        let w = l.timedWords(inLine: 0, trackDuration: 60)
        #expect(w.count == 2)
        #expect(w[0].start == 10)
        #expect(abs(w[0].end - 11) < 1e-9)   // 3 s * 2/6
        #expect(abs(w[1].end - 13) < 1e-9)
    }

    @Test func longSilenceDoesNotStretchWords() {
        let l = LRCParser.parse("[00:10.00]un deux\n[01:00.00]x")
        let w = l.timedWords(inLine: 0, trackDuration: 120)
        #expect(w.last!.end <= 13.0 + 1e-9)  // 2 mots -> au plus 3 s
    }
}
