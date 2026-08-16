import AppKit
import AppNTFSKit
import SwiftUI

struct VolumeRowView: View {
    let volume: NTFSVolume
    let isIgnored: Bool
    let onRetry: () -> Void
    let onFixAndRetry: () -> Void
    let onEject: () -> Void
    let onToggleIgnored: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(volume.volumeName)
                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if showsRetry {
                Button("Reintentar", action: onRetry)
            }
            if isDirty {
                Button("Reparar y reintentar", action: onFixAndRetry)
                    .help("Limpia el flag de hibernación de Windows (ntfsfix) y vuelve a montar en escritura.")
            }
            Button("Abrir") {
                NSWorkspace.shared.open(URL(fileURLWithPath: volume.mountPath))
            }
            Button("Expulsar", action: onEject)
            Button(isIgnored ? "Dejar de ignorar" : "Ignorar", action: onToggleIgnored)
                .disabled(volume.volumeUUID == nil)
        }
    }

    private var showsRetry: Bool {
        switch volume.mountState {
        case .readOnly, .error:
            return true
        case .mounting, .readWrite:
            return false
        }
    }

    private var isDirty: Bool {
        if case .error(.volumeDirty) = volume.mountState { return true }
        return false
    }

    private var stateLabel: String {
        let base: String
        switch volume.mountState {
        case .readOnly: base = "Solo lectura"
        case .mounting: base = "Montando…"
        case .readWrite: base = "Lectura/escritura"
        case .error(let error): base = error.description
        }
        return isIgnored ? "\(base) — ignorado" : base
    }
}
