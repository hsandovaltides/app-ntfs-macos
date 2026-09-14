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

        FSKitSetupView(
            status: coordinator.dependencyStatus,
            volumes: coordinator.volumes
        )

        if coordinator.volumes.isEmpty {
            Text("No hay volúmenes NTFS conectados")
        } else {
            ForEach(coordinator.volumes) { volume in
                VolumeRowView(
                    volume: volume,
                    isIgnored: coordinator.isIgnored(volume),
                    isOperating: coordinator.isOperating(volume),
                    onRetry: { coordinator.retryMount(volume) },
                    onFixAndRetry: { coordinator.fixAndRetryMount(volume) },
                    onCancel: { coordinator.cancelOperation(volume) },
                    onEject: { coordinator.eject(volume) },
                    onToggleIgnored: { coordinator.setIgnored(!coordinator.isIgnored(volume), for: volume) }
                )
            }
        }

        Divider()

        // Only shown when there is actually something newer — the app is
        // distributed as a zip and a Homebrew cask, neither of which tells a
        // running copy it has fallen behind.
        if let update = coordinator.availableUpdate {
            Button("Actualizar a \(update.version)…") { coordinator.openReleasePage() }
        }

        Toggle("Remontar automáticamente", isOn: $coordinator.autoRemountEnabled)

        SettingsLink {
            Text("Preferencias…")
        }

        Button("Ver registros…") { openWindow(id: "logs") }

        Button("Recomprobar dependencias") {
            Task { await coordinator.recheckDependencies() }
        }

        Button("Buscar actualizaciones") { coordinator.checkForUpdates(userInitiated: true) }

        Divider()

        Button("Salir") { NSApplication.shared.terminate(nil) }
    }
}
