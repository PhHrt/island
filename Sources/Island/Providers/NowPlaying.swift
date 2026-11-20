import AppKit
import SwiftUI

enum NowPlayingCommand: String {
    case toggle, next, prev
}

/// État de lecture tel que remonté par le helper MediaRemote.
struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    /// Position au moment `timestamp`.
    var elapsed: Double
    var timestamp: Date
    var rate: Double
    var isPlaying: Bool
    var bundleID: String?
    var appName: String?
    var artwork: NSImage?
    var artworkPath: String?
    var accent: Color

    /// Position estimée maintenant, sans attendre le prochain message du helper.
    func elapsed(at date: Date) -> Double {
        guard isPlaying, rate > 0 else { return min(elapsed, duration) }
        let e = elapsed + date.timeIntervalSince(timestamp) * rate
        return duration > 0 ? min(max(e, 0), duration) : max(e, 0)
    }

    static func == (a: NowPlaying, b: NowPlaying) -> Bool {
        a.title == b.title && a.artist == b.artist && a.album == b.album && a.duration == b.duration
            && a.elapsed == b.elapsed && a.timestamp == b.timestamp && a.rate == b.rate
            && a.isPlaying == b.isPlaying && a.bundleID == b.bundleID && a.artworkPath == b.artworkPath
            && a.artwork === b.artwork
    }
}

/// Message JSON émis chaque seconde par le helper.
struct NowPlayingMessage: Decodable {
    var empty: Bool?
    var error: String?
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
    var elapsed: Double?
    var rate: Double?
    var timestamp: Double?
    var artwork: String?
    var playing: Bool?
    var pid: Int32?
}

enum Artwork {
    /// Couleur moyenne de la pochette, éclaircie si elle est trop sombre pour ressortir sur le noir.
    static func accent(of image: NSImage) -> Color {
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else { return .white }
        let filter = CIFilter(name: "CIAreaAverage",
                              parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)])
        guard let output = filter?.outputImage else { return .white }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()])
            .render(output, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBA8, colorSpace: nil)
        var color = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                            blue: CGFloat(px[2]) / 255, alpha: 1)
        if let hsb = color.usingColorSpace(.deviceRGB) {
            let b = max(hsb.brightnessComponent, 0.75)
            let s = min(hsb.saturationComponent * 1.2, 1)
            color = NSColor(hue: hsb.hueComponent, saturation: s, brightness: b, alpha: 1)
        }
        return Color(nsColor: color)
    }
}
