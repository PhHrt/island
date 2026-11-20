// Spike A — appel direct à MediaRemote depuis notre propre binaire.
// Attendu : bloqué depuis macOS 15.4 pour les processus non Apple (dictionnaire vide).
import Foundation

let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
guard let handle = dlopen(path, RTLD_NOW) else {
    print("[direct] dlopen MediaRemote a échoué")
    exit(1)
}

typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void

guard let infoSym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo"),
      let playingSym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else {
    print("[direct] symboles introuvables")
    exit(1)
}
let getInfo = unsafeBitCast(infoSym, to: GetInfoFn.self)
let isPlaying = unsafeBitCast(playingSym, to: IsPlayingFn.self)

let done = DispatchSemaphore(value: 0)
getInfo(DispatchQueue.global()) { dict in
    let d = (dict as? [String: Any]) ?? [:]
    if d.isEmpty {
        print("[direct] info: VIDE (bloqué ou rien en lecture)")
    } else {
        let title = d["kMRMediaRemoteNowPlayingInfoTitle"] ?? "?"
        let artist = d["kMRMediaRemoteNowPlayingInfoArtist"] ?? "?"
        let hasArt = d["kMRMediaRemoteNowPlayingInfoArtworkData"] != nil
        print("[direct] info: \(title) — \(artist) | pochette: \(hasArt) | \(d.count) clés")
    }
    done.signal()
}
_ = done.wait(timeout: .now() + 3)

isPlaying(DispatchQueue.global()) { playing in
    print("[direct] en lecture: \(playing)")
    done.signal()
}
_ = done.wait(timeout: .now() + 3)
