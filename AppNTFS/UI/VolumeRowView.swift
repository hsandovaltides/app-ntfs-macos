import AppKit
import AppNTFSKit
import SwiftUI

struct VolumeRowView: View {
    let volume: NTFSVolume
    let isIgnored: Bool
    let isOperating: Bool
    let onRetry: () -> Void
    let onFixAndRetry: () -> Void
    let onCancel: () -> Void
    let onEject: () -> Void
    let onToggleIgnored: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(volume.volumeName)
                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // The full diagnostic on hover. `MountError.description` is
            // deliberately one condensed line so it fits a notification and a
            // menu row; `detail` is the untruncated text, which for the
            // mount-and-fallback-both-failed case is the only place both
            // underlying errors are visible outside the log.
            .help(stateDetail ?? stateLabel)
            Spacer()
            if isOperating {
                Button("Cancelar", action: onCancel)
                    .help("Detiene el montaje en curso. El volumen queda en solo lectura.")
            }
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
            .disabled(volume.mountPath.isEmpty)
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

    /// Tooltip text: the untruncated failure reason when there is one,
    /// otherwise the mountpoint, which is the other thing a row can't show.
    private var stateDetail: String? {
        if case .error(let error) = volume.mountState, let detail = error.detail {
            return detail
        }
        return volume.mountPath.isEmpty ? nil : volume.mountPath
    }
}
