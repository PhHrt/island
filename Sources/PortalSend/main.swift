// portal-send : envoie un fichier ou du texte à Island comme le ferait l'iPhone (tests en local).
// Usage : portal-send <lien islandportal://pair?...> <port> (--text "…" | <fichier>) [transition]
import Foundation
import PortalKit

let args = CommandLine.arguments
guard args.count >= 4, let url = URL(string: args[1]), let pairing = PortalPairing(url: url), let port = UInt16(args[2]) else {
    print("usage: portal-send <lien d'appairage> <port> (--text \"…\" | <fichier>) [transition]")
    exit(2)
}
let client = PortalClient(host: "127.0.0.1", port: port, key: pairing.key, senderName: "portal-send")
do {
    try await client.connect()
    if args[3] == "--text", args.count >= 5 {
        try await client.sendText(args[4])
        print("texte envoyé")
    } else {
        let file = URL(fileURLWithPath: args[3])
        let name = try await client.sendFile(file, transition: args.count >= 5 ? args[4] : "slide") { f in
            print(String(format: "\r%3.0f %%", f * 100), terminator: "")
            fflush(stdout)
        }
        print("\nreçu par le Mac sous le nom : \(name)")
    }
    client.close()
} catch {
    print("échec : \(error.localizedDescription)")
    exit(1)
}
