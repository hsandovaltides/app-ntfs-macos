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

                if status.homebrewPrefix == nil {
                    Text("Instalá Homebrew desde brew.sh").font(.callout)
                }

                if !status.ntfs3gInstalled {
                    instructionRow(
                        "Instalar macFUSE + ntfs-3g-mac",
                        command: "brew install --cask macfuse && brew tap gromgit/homebrew-fuse && brew install ntfs-3g-mac"
                    )
                }

                switch status.macFUSEState {
                case .notInstalled where status.ntfs3gInstalled:
                    instructionRow("Instalar macFUSE", command: "brew install --cask macfuse")
                case .installedPendingApproval:
                    Text("macFUSE necesita aprobación en Ajustes del Sistema").font(.callout)
                    Button("Abrir Ajustes del Sistema", action: openSystemSettings)
                default:
                    EmptyView()
                }

                switch status.helperState {
                case .installedPendingApproval:
                    Text("El helper privilegiado (necesario para montar en escritura) espera aprobación en Ajustes del Sistema → Elementos de inicio y extensiones")
                        .font(.callout)
                    Button("Abrir Ajustes del Sistema", action: openSystemSettings)
                case .notInstalled, .installedAndApproved:
                    EmptyView()
                }

                if status.helperState == .installedAndApproved, !status.fullDiskAccessGranted {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Falta \"Acceso completo al disco\" para el helper — sin esto, macOS bloquea la lectura del disco incluso para el proceso root.")
                            .font(.callout)
                        HStack {
                            Button("Abrir Ajustes del Sistema", action: openFullDiskAccessSettings)
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
            }
        }
    }

    /// Best-effort deep link into Privacy & Security — Apple has reshuffled
    /// System Settings across recent macOS versions, so this may land on the
    /// general pane rather than the exact Extensions sub-section.
    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    /// `Privacy_AllFiles` is the documented anchor for the Full Disk Access
    /// list specifically (vs. the generic Security pane `openSystemSettings`
    /// opens) — same best-effort caveat applies across macOS versions.
    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
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
