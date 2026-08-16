import SwiftUI

struct PreferencesView: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Form {
            Toggle("Remontar automáticamente volúmenes NTFS nuevos", isOn: $coordinator.autoRemountEnabled)
            Toggle("Notificarme sobre montajes y errores", isOn: $coordinator.notificationsEnabled)
            Toggle("Iniciar al iniciar sesión", isOn: Binding(
                get: { coordinator.launchAtLoginEnabled },
                set: { coordinator.setLaunchAtLogin($0) }
            ))

            Section {
                Text(Self.versionString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 380)
    }

    /// Reads from the bundle's Info.plist (populated from `MARKETING_VERSION`
    /// / `CURRENT_PROJECT_VERSION` at build time — the release workflow sets
    /// these per tag) rather than hardcoding a version here, so this can't
    /// drift out of sync with what actually got built.
    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = info?["CFBundleVersion"] as? String ?? "?"
        return "AppNTFS \(shortVersion) (\(buildNumber))"
    }
}
