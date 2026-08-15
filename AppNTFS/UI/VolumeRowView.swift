import AppKit
import AppNTFSKit
import SwiftUI

struct VolumeRowView: View {
    let volume: NTFSVolume
    let onRetry: () -> Void
    let onEject: () -> Void

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
        switch volume.mountState {
        case .readOnly: return "Solo lectura"
        case .mounting: return "Montando…"
        case .readWrite: return "Lectura/escritura"
        case .error(let message): return message
        }
    }
}
