import Foundation
import Testing
@testable import IslandCore

@Suite("Égaliseur")
struct EqualizerTests {
    let sr = 48_000.0

    @Test func zeroGainIsIdentity() {
        #expect(Biquad(kind: .peaking, frequency: 1000, gainDB: 0, q: 1.41, sampleRate: sr) == .identity)
        #expect(Equalizer.filters(for: Array(repeating: 0, count: 10), sampleRate: sr).allSatisfy { $0 == .identity })
    }

    @Test func peakingHitsTargetGainAtCenter() {
        let f = Biquad(kind: .peaking, frequency: 1000, gainDB: 6, q: 1.41, sampleRate: sr)
        #expect(abs(f.responseDB(at: 1000, sampleRate: sr) - 6) < 0.05)
        #expect(abs(f.responseDB(at: 50, sampleRate: sr)) < 0.3)
        #expect(abs(f.responseDB(at: 15000, sampleRate: sr)) < 0.3)
        #expect(f.isStable)
    }

    @Test func shelvesBoostTheirSide() {
        let low = Biquad(kind: .lowShelf, frequency: 32, gainDB: 8, q: 0.71, sampleRate: sr)
        #expect(abs(low.responseDB(at: 10, sampleRate: sr) - 8) < 0.5)
        #expect(abs(low.responseDB(at: 2000, sampleRate: sr)) < 0.2)
        let high = Biquad(kind: .highShelf, frequency: 16000, gainDB: -8, q: 0.71, sampleRate: sr)
        #expect(high.responseDB(at: 20000, sampleRate: sr) < -5)
        #expect(abs(high.responseDB(at: 500, sampleRate: sr)) < 0.2)
    }

    @Test func allPresetsAreStableAndValid() {
        for preset in Equalizer.presets {
            #expect(preset.gains.count == Equalizer.bandCount, "\(preset.name)")
            for sampleRate in [44_100.0, 48_000, 96_000] {
                let stable = Equalizer.filters(for: preset.gains, sampleRate: sampleRate).allSatisfy { $0.isStable }
                #expect(stable, "\(preset.name)")
            }
        }
    }

    @Test func preampCompensatesBoost() {
        #expect(Equalizer.preampDB(for: [6, 0, -3]) == -6)
        #expect(Equalizer.preampDB(for: [-3, -1]) == 0)
        // Avec le préampli, la courbe ne dépasse pas beaucoup 0 dB.
        let curve = Equalizer.curve(gains: Equalizer.presets[1].gains, at: [20, 32, 64, 125, 1000, 8000])
        #expect(curve.allSatisfy { $0 < 1.5 })
    }

    @Test func clampsOutOfRangeGains() {
        let a = Equalizer.filters(for: [40] + Array(repeating: 0, count: 9), sampleRate: sr)
        let b = Equalizer.filters(for: [12] + Array(repeating: 0, count: 9), sampleRate: sr)
        #expect(a == b)
    }

    /// Amplitude crête d'un sinus de fréquence `f` après traitement (en régime établi).
    private func peakAfterProcessing(gains: [Double], frequency f: Double) -> Float {
        let p = EQProcessor(channels: 2, sampleRate: sr, gains: gains)
        let frames = 9600
        var buf = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Float(0.25 * sin(2 * Double.pi * f * Double(i) / sr))
            buf[2 * i] = v
            buf[2 * i + 1] = v
        }
        buf.withUnsafeMutableBufferPointer { p.process($0.baseAddress!, frames: frames) }
        return buf[(frames)...].map(abs).max() ?? 0
    }

    @Test func processorFlatPassesThrough() {
        let peak = peakAfterProcessing(gains: Array(repeating: 0, count: 10), frequency: 1000)
        #expect(abs(peak - 0.25) < 0.002)
    }

    @Test func processorBoostsTheBand() {
        // +6 dB à 1 kHz, préampli -6 dB : 1 kHz reste à ~0,25, 64 Hz descend à ~0,125.
        var gains = Array(repeating: 0.0, count: 10)
        gains[5] = 6
        #expect(abs(peakAfterProcessing(gains: gains, frequency: 1000) - 0.25) < 0.01)
        #expect(abs(peakAfterProcessing(gains: gains, frequency: 64) - 0.125) < 0.01)
    }

    @Test func profileCodableRoundTrip() throws {
        let p = EQProfile(enabled: true, gains: Equalizer.presets[2].gains, preset: "Aigus")
        let back = try JSONDecoder().decode(EQProfile.self, from: JSONEncoder().encode(p))
        #expect(back == p)
        #expect(!back.isFlat)
    }
}
