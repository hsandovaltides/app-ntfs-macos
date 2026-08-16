import AppKit
import AppNTFSKit
import SwiftUI

struct VolumeRowView: View {
    let volume: NTFSVolume
    let isIgnored: Bool
    let onRetry: () -> Void
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

    private var stateLabel: String {
        let base: String
        switch volume.mountState {
        case .readOnly: base = "Solo lectura"
        case .mounting: base = "Montando…"
        case .readWrite: base = "Lectura/escritura"
        case .error(let message): base = message
        }
        return isIgnored ? "\(base) — ignorado" : base
    }
}
