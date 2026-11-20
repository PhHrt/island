import CoreImage.CIFilterBuiltins
import PortalKit
import SwiftUI

/// Appairage de l'iPhone (QR code), dossier de réception, état du serveur.
struct PortalSettings: View {
    @AppStorage(Prefs.Key.portal) private var enabled = true
    @AppStorage(Prefs.Key.portalFolder) private var folder = ""
    @State private var portal = PortalService.shared
    @State private var copied = false
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Toggle("Recevoir les fichiers de l'iPhone (Portal)", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in portal.applyPreference() }
                LabeledContent("État") {
                    if let e = portal.lastError {
                        Text(e).foregroundStyle(.red)
                    } else {
                        Text(portal.isRunning ? "Prêt sur le réseau local" : "Arrêté")
                            .foregroundStyle(portal.isRunning ? .green : .secondary)
                    }
                }
                if let p = portal.progress {
                    ProgressView(value: p.fraction) { Text("Réception de \(p.name)") }
                }
            } footer: {
                Text("Uniquement sur le réseau local, chiffré (TLS avec la clé du QR code). Rien ne passe par Internet.")
            }

            Section("Appairer l'iPhone") {
                HStack(alignment: .top, spacing: 18) {
                    QRCodeView(text: portal.pairing.url.absoluteString)
                        .frame(width: 150, height: 150)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scanne ce code avec l'app Island Portal sur ton iPhone.")
                        LabeledContent("Mac", value: portal.pairing.macName)
                        LabeledContent("Empreinte", value: portal.pairing.fingerprint).monospaced()
                        Text("Vérifie que la même empreinte s'affiche sur l'iPhone.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(copied ? "Copié" : "Copier le lien") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(portal.pairing.url.absoluteString, forType: .string)
                                copied = true
                            }
                            Button("Nouvelle clé…") { confirmReset = true }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Réception") {
                LabeledContent("Dossier", value: portal.destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                Button("Choisir un dossier…") { chooseFolder() }
                if let port = portal.port {
                    LabeledContent("Port (debug)", value: "\(port)").font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Créer une nouvelle clé ?", isPresented: $confirmReset) {
            Button("Nouvelle clé", role: .destructive) { portal.regenerateKey() }
        } message: {
            Text("L'iPhone déjà appairé ne pourra plus envoyer tant qu'il n'a pas scanné le nouveau code.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = portal.destination
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.path
            portal.restart()
        }
    }
}

/// QR code net (pas de lissage) généré par Core Image.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.make(text) {
            Image(nsImage: image).interpolation(.none).resizable().aspectRatio(1, contentMode: .fit)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white))
        }
    }

    static func make(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: out.extent.width, height: out.extent.height))
    }
}
