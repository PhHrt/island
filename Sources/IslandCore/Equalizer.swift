import Foundation
import os

/// Coefficients d'un filtre biquad normalisés (a0 = 1), formules du « Audio EQ Cookbook » (R. Bristow-Johnson).
public struct Biquad: Equatable, Sendable {
    public var b0, b1, b2, a1, a2: Double

    public static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    public enum Kind: Sendable { case peaking, lowShelf, highShelf }

    public init(kind: Kind, frequency: Double, gainDB: Double, q: Double, sampleRate: Double) {
        guard abs(gainDB) > 0.01, frequency > 0, frequency < sampleRate / 2 else { self = .identity; return }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * q)
        var b0, b1, b2, a0, a1, a2: Double
        switch kind {
        case .peaking:
            b0 = 1 + alpha * a; b1 = -2 * cosw; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cosw; a2 = 1 - alpha / a
        case .lowShelf:
            let s = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) - (a - 1) * cosw + s)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
            b2 = a * ((a + 1) - (a - 1) * cosw - s)
            a0 = (a + 1) + (a - 1) * cosw + s
            a1 = -2 * ((a - 1) + (a + 1) * cosw)
            a2 = (a + 1) + (a - 1) * cosw - s
        case .highShelf:
            let s = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) + (a - 1) * cosw + s)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
            b2 = a * ((a + 1) + (a - 1) * cosw - s)
            a0 = (a + 1) - (a - 1) * cosw + s
            a1 = 2 * ((a - 1) - (a + 1) * cosw)
            a2 = (a + 1) - (a - 1) * cosw - s
        }
        self.init(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Gain (dB) du filtre à la fréquence `f`.
    public func responseDB(at f: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * f / sampleRate
        // H(z) = (b0 + b1 z^-1 + b2 z^-2) / (1 + a1 z^-1 + a2 z^-2), z = e^{jw}
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        let mag = ((nr * nr + ni * ni) / (dr * dr + di * di)).squareRoot()
        return 20 * log10(max(mag, 1e-12))
    }

    /// Pôles dans le cercle unité : le filtre ne diverge pas.
    public var isStable: Bool { abs(a2) < 1 && abs(a1) < 1 + a2 }
}

/// Réglage d'égaliseur d'une app : 10 bandes, gains en dB.
public struct EQProfile: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var gains: [Double]
    public var preset: String?

    public init(enabled: Bool = false, gains: [Double] = Array(repeating: 0, count: Equalizer.bandCount), preset: String? = "Plat") {
        self.enabled = enabled
        self.gains = gains
        self.preset = preset
    }

    public var isFlat: Bool { gains.allSatisfy { abs($0) < 0.05 } }
}

public enum Equalizer {
    public static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static var bandCount: Int { frequencies.count }
    public static let gainRange: ClosedRange<Double> = -12...12
    /// Q d'une bande d'octave.
    public static let q = 1.41

    public static let presets: [(name: String, gains: [Double])] = [
        ("Plat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Basses", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Aigus", [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        ("Voix", [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        ("Loudness", [5, 4, 2, 0, -1, -1, 0, 2, 4, 5]),
        ("Podcast", [-4, -3, -1, 1, 3, 3, 2, 0, -2, -4]),
        ("Électro", [5, 4, 1, 0, -2, 1, 0, 2, 4, 4]),
        ("Rock", [4, 3, 2, 0, -1, -1, 1, 3, 4, 4]),
        ("Acoustique", [3, 2, 1, 1, 2, 2, 3, 3, 2, 1]),
    ]

    public static func filters(for gains: [Double], sampleRate: Double) -> [Biquad] {
        frequencies.enumerated().map { i, f in
            let g = i < gains.count ? min(max(gains[i], gainRange.lowerBound), gainRange.upperBound) : 0
            let kind: Biquad.Kind = i == 0 ? .lowShelf : (i == frequencies.count - 1 ? .highShelf : .peaking)
            return Biquad(kind: kind, frequency: f, gainDB: g, q: kind == .peaking ? q : 0.71, sampleRate: sampleRate)
        }
    }

    /// Atténuation appliquée avant les filtres pour éviter la saturation quand on monte des bandes.
    public static func preampDB(for gains: [Double]) -> Double {
        -max(0, gains.max() ?? 0)
    }

    /// Courbe totale (dB) aux fréquences données, préampli compris : sert à dessiner la courbe dans les réglages.
    public static func curve(gains: [Double], at freqs: [Double], sampleRate: Double = 48_000) -> [Double] {
        let fs = filters(for: gains, sampleRate: sampleRate)
        let pre = preampDB(for: gains)
        return freqs.map { f in fs.reduce(pre) { $0 + $1.responseDB(at: f, sampleRate: sampleRate) } }
    }
}

/// Traitement temps réel : cascade de biquads par canal sur de l'audio float entrelacé.
/// `update(gains:)` peut être appelé depuis l'UI ; `process` (thread audio) ne bloque jamais :
/// il récupère les nouveaux coefficients seulement si le verrou est libre.
public final class EQProcessor: @unchecked Sendable {
    public let channels: Int
    public let sampleRate: Double
    private let bands = Equalizer.bandCount

    // Coefficients actifs (thread audio) et en attente (UI), en Float pour le calcul.
    private var active: UnsafeMutablePointer<Float>
    private var pending: UnsafeMutablePointer<Float>
    private var pendingPreamp: Float = 1
    private var activePreamp: Float = 1
    private var hasPending = false
    private var lock = os_unfair_lock()
    // État TDF2 : 2 valeurs par bande et par canal.
    private var state: UnsafeMutablePointer<Float>

    public init(channels: Int, sampleRate: Double, gains: [Double]) {
        self.channels = max(1, channels)
        self.sampleRate = sampleRate
        active = .allocate(capacity: bands * 5)
        pending = .allocate(capacity: bands * 5)
        state = .allocate(capacity: bands * 2 * self.channels)
        state.initialize(repeating: 0, count: bands * 2 * self.channels)
        Self.write(Equalizer.filters(for: gains, sampleRate: sampleRate), into: active)
        activePreamp = Float(pow(10, Equalizer.preampDB(for: gains) / 20))
        pending.initialize(from: active, count: bands * 5)
    }

    deinit {
        active.deallocate()
        pending.deallocate()
        state.deallocate()
    }

    private static func write(_ filters: [Biquad], into p: UnsafeMutablePointer<Float>) {
        for (i, f) in filters.enumerated() {
            p[i * 5 + 0] = Float(f.b0); p[i * 5 + 1] = Float(f.b1); p[i * 5 + 2] = Float(f.b2)
            p[i * 5 + 3] = Float(f.a1); p[i * 5 + 4] = Float(f.a2)
        }
    }

    public func update(gains: [Double]) {
        let filters = Equalizer.filters(for: gains, sampleRate: sampleRate)
        let pre = Float(pow(10, Equalizer.preampDB(for: gains) / 20))
        os_unfair_lock_lock(&lock)
        Self.write(filters, into: pending)
        pendingPreamp = pre
        hasPending = true
        os_unfair_lock_unlock(&lock)
    }

    /// Traite `frames` trames entrelacées en place (`samples` contient frames × channels valeurs).
    public func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        if os_unfair_lock_trylock(&lock) {
            if hasPending {
                active.update(from: pending, count: bands * 5)
                activePreamp = pendingPreamp
                hasPending = false
            }
            os_unfair_lock_unlock(&lock)
        }
        let ch = channels
        let pre = activePreamp
        for c in 0..<ch {
            var idx = c
            for _ in 0..<frames {
                var x = samples[idx] * pre
                for b in 0..<bands {
                    let k = active + b * 5
                    let s = state + (c * bands + b) * 2
                    let y = k[0] * x + s[0]
                    s[0] = k[1] * x - k[3] * y + s[1]
                    s[1] = k[2] * x - k[4] * y
                    x = y
                }
                // Garde-fou : le préampli évite déjà la saturation, on borne au cas où.
                x = min(max(x, -1), 1)
                samples[idx] = x
                idx += ch
            }
        }
        // Évite les dénormaux qui font exploser le CPU sur les silences.
        for i in 0..<(bands * 2 * ch) where abs(state[i]) < 1e-20 { state[i] = 0 }
    }

    public func reset() {
        state.update(repeating: 0, count: bands * 2 * channels)
    }
}
