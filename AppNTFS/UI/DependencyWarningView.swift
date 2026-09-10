import AppKit
import AppNTFSKit
import SwiftUI

struct DependencyWarningView: View {
    let status: DependencyStatus?
    let onRecheck: () -> Void

    var body: some View {
        if let status, !status.isReady {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dependencias faltantes")
                    .font(.headline)

                if let install = InstallStep(status: status) {
                    if status.homebrewPrefix == nil {
                        // Homebrew is only ever mentioned as the *delivery
                        // mechanism* for something actually missing — it is
                        // not a dependency of this app. With ntfs-3g embedded
                        // in the bundle, a machine with no Homebrew at all is
                        // a perfectly ready one.
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(install.title): hace falta Homebrew para instalarlo desde acá.")
                                .font(.callout)
                            Button("Abrir brew.sh") {
                                NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
                            }
                        }
                    } else {
                        instructionRow(install.title, command: install.command)
                    }

                    if install.includesMacFUSE {
                        // macFUSE also ships a plain installer package, which
                        // is the only route left if the user doesn't want
                        // Homebrew on their machine.
                        Button("Descargar macFUSE sin Homebrew") {
                            NSWorkspace.shared.open(URL(string: "https://macfuse.io")!)
                        }
                        .buttonStyle(.link)
                    }
                }

                switch status.macFUSEState {
                case .installedPendingApproval:
                    Text("macFUSE necesita aprobación en Ajustes del Sistema → Privacidad y Seguridad")
                        .font(.callout)
                    Button("Abrir Privacidad y Seguridad") { SystemSettingsLink.privacyAndSecurity.open() }
                default:
                    EmptyView()
                }

                switch status.helperState {
                case .installedPendingApproval:
                    Text("El helper privilegiado (necesario para montar en escritura) espera aprobación en Ajustes del Sistema → Elementos de inicio y extensiones")
                        .font(.callout)
                    Button("Abrir Elementos de inicio") { SystemSettingsLink.loginItems.open() }
                case .notInstalled, .installedAndApproved:
                    EmptyView()
                }

                if status.helperState == .installedAndApproved, !status.fullDiskAccessGranted {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Falta \"Acceso completo al disco\" para el helper — sin esto, macOS bloquea la lectura del disco incluso para el proceso root.")
                            .font(.callout)
                        HStack {
                            Button("Abrir Acceso completo al disco") { SystemSettingsLink.fullDiskAccess.open() }
                            Button("Mostrar el helper en Finder", action: revealHelperInFinder)
                        }
                        Text("Arrastrá el archivo que se abre en Finder a la lista de Ajustes → Privacidad y Seguridad → Acceso completo al disco.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Recomprobar", action: onRecheck)
            }
            .padding(8)

            Divider()
        }
    }

    /// The one install command that covers everything currently missing, so
    /// the user runs a single line instead of one per row.
    private struct InstallStep {
        let title: String
        let command: String
        let includesMacFUSE: Bool

        init?(status: DependencyStatus) {
            let needsMacFUSE = status.macFUSEState == .notInstalled
            let needsNtfs3g = !status.ntfs3gInstalled

            switch (needsMacFUSE, needsNtfs3g) {
            case (false, false):
                return nil
            case (true, false):
                title = "Instalar macFUSE"
                command = "brew install --cask macfuse"
            case (false, true):
                title = "Instalar ntfs-3g"
                command = "brew tap gromgit/homebrew-fuse && brew install ntfs-3g-mac"
            case (true, true):
                title = "Instalar macFUSE + ntfs-3g"
                command = "brew install --cask macfuse && brew tap gromgit/homebrew-fuse && brew install ntfs-3g-mac"
            }
            includesMacFUSE = needsMacFUSE
        }
    }

    private func instructionRow(_ title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout)
            HStack {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copiar el comando")
            }
            Button("Ejecutar en Terminal") {
                TerminalCommand.run(command, title: title)
            }
        }
    }

    /// Full Disk Access can only be granted by the user dragging the exact
    /// binary into the Settings list (or via its "+" file picker) — no API
    /// lets an app add itself. Selecting it in Finder is the closest we can
    /// get to a one-click flow.
    private func revealHelperInFinder() {
        let helperPath = Bundle.main.bundlePath + "/Contents/MacOS/AppNTFSHelper"
        NSWorkspace.shared.selectFile(helperPath, inFileViewerRootedAtPath: "")
    }
}
