import AppNTFSKit
import SwiftUI

/// The one manual step left on a machine that can use macFUSE's FSKit backend:
/// switching the file-system extension on.
///
/// Separate from `DependencyWarningView` because it is not a missing
/// dependency. Everything *is* installed — `DependencyStatus.isReady` is true,
/// so that banner is hidden — and the mount still fails, because the extension
/// ships switched off and nothing but the user can flip it (no API, no command;
/// even a PluginKit-registered extension reports "File system extension not
/// enabled" until the toggle is on).
///
/// It is therefore shown reactively, off an actual mount failure, rather than
/// as a standing instruction: on a machine where FSKit is already enabled — or
/// where the kext fallback quietly does the job — the user never sees it.
struct FSKitSetupView: View {
    let status: DependencyStatus?
    let volumes: [NTFSVolume]

    var body: some View {
        if shouldShow {
            VStack(alignment: .leading, spacing: 6) {
                Text("El montaje falló")
                    .font(.headline)

                Text("macFUSE puede montar sin extensión de kernel (sin Modo Recuperación ni reinicios), pero para eso hay que activar su extensión del sistema de archivos.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Ajustes del Sistema → General → Elementos de inicio y extensiones → Extensiones del sistema de archivos → activar macFUSE.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Abrir Extensiones del sistema de archivos") {
                    SystemSettingsLink.fileSystemExtensions.open()
                }

                // Second, and phrased as a fallback, because it is only needed
                // when macFUSE left its extensions unregistered — in which case
                // the button above lands on a list that doesn't mention macFUSE
                // at all, and the user has nothing to switch on.
                Text("Si macFUSE no aparece en esa lista, registrá sus extensiones y volvé a mirar:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Registrar extensiones de macFUSE") {
                    TerminalCommand.run(
                        FuseBackendAvailability.registrationCommand,
                        title: "Registrar las extensiones FSKit de macFUSE"
                    )
                }
            }
            .padding(8)

            Divider()
        }
    }

    /// Shown only when FSKit is plausible *and* a mount actually failed.
    ///
    /// `.dependenciesNotReady` and `.volumeDirty` are deliberately excluded:
    /// the first has its own banner, and the second is a Windows dirty flag
    /// with its own "Reparar y reintentar" button — neither has anything to do
    /// with the extension, and offering this on top would send the user to
    /// change a setting that was never the problem.
    private var shouldShow: Bool {
        guard status?.fskitBackendAvailable == true else { return false }
        return volumes.contains { volume in
            switch volume.mountState {
            case .error(.mountFailed), .error(.mountFailedAndFallbackFailed):
                return true
            default:
                return false
            }
        }
    }
}
