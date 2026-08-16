import AppKit
import AppNTFSKit
import SwiftUI

struct MenuBarContentView: View {
    @Bindable var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        DependencyWarningView(status: coordinator.dependencyStatus) {
            Task { await coordinator.recheckDependencies() }
        }

        if coordinator.volumes.isEmpty {
            Text("No hay volúmenes NTFS conectados")
        } else {
            ForEach(coordinator.volumes) { volume in
                VolumeRowView(
                    volume: volume,
                    isIgnored: coordinator.isIgnored(volume),
                    onRetry: { coordinator.retryMount(volume) },
                    onEject: { coordinator.eject(volume) },
                    onToggleIgnored: { coordinator.setIgnored(!coordinator.isIgnored(volume), for: volume) }
                )
            }
        }

        Divider()

        Toggle("Remontar automáticamente", isOn: $coordinator.autoRemountEnabled)

        SettingsLink {
            Text("Preferencias…")
        }

        Button("Ver registros…") { openWindow(id: "logs") }

        Button("Recomprobar dependencias") {
            Task { await coordinator.recheckDependencies() }
        }

        Divider()

        Button("Salir") { NSApplication.shared.terminate(nil) }
    }
}
