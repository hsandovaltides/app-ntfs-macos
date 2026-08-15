import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }
}

@main
struct AppNTFSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(coordinator: appDelegate.coordinator)
        } label: {
            Image(systemName: appDelegate.coordinator.statusSymbolName)
        }
        .menuBarExtraStyle(.menu)

        Window("Registros", id: "logs") {
            LogsView(coordinator: appDelegate.coordinator)
        }

        Settings {
            PreferencesView(coordinator: appDelegate.coordinator)
        }
    }
}
