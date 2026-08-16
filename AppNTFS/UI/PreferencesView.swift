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
        }
        .padding()
        .frame(width: 380)
    }
}
