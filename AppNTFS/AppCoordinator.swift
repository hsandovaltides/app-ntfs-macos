import AppNTFSKit
import Observation
import ServiceManagement
import UserNotifications

private enum PreferencesKey {
    static let autoRemountEnabled = "autoRemountEnabled"
    static let notificationsEnabled = "notificationsEnabled"
    static let ignoredVolumeUUIDs = "ignoredVolumeUUIDs"
}

/// Presenting notification banners while the app itself is the frontmost
/// process (which a menu-bar/agent app can still be while its menu is open)
/// requires an explicit delegate — otherwise UNUserNotificationCenter
/// silently swallows them. Kept as its own NSObject subclass rather than
/// making AppCoordinator inherit NSObject just for this.
private final class MountNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

@MainActor
@Observable
final class AppCoordinator {
    private(set) var volumes: [NTFSVolume] = []
    private(set) var dependencyStatus: DependencyStatus?
    var autoRemountEnabled = true {
        didSet { UserDefaults.standard.set(autoRemountEnabled, forKey: PreferencesKey.autoRemountEnabled) }
    }
    var notificationsEnabled = true {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: PreferencesKey.notificationsEnabled) }
    }
    /// Volumes the user opted out of auto-remount for, keyed by
    /// `NTFSVolume.volumeUUID` (not `bsdName` — that's reassigned by macOS
    /// across reconnects/reboots, confirmed across this session's own
    /// testing, so it can't identify "this same drive" persistently).
    private(set) var ignoredVolumeUUIDs: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(ignoredVolumeUUIDs), forKey: PreferencesKey.ignoredVolumeUUIDs) }
    }

    let logger = AppLogger.shared
    private let notificationDelegate = MountNotificationDelegate()

    private let diskWatcher = DiskWatcher()
    // PrivilegedHelperMounter is stateless (a fresh XPC connection is opened
    // per call regardless), so two separate instances here cost nothing —
    // keeps both properties as plain `let`, which @Observable's macro
    // expansion requires (no `lazy` on its computed accessors).
    private let mountManager = MountManager(privilegedMounter: PrivilegedHelperMounter())
    private let dependencyChecker = DependencyChecker(fullDiskAccessProbe: PrivilegedHelperMounter())
    private var watchTask: Task<Void, Never>?

    var statusSymbolName: String {
        guard let dependencyStatus, dependencyStatus.isReady else {
            return "externaldrive.trianglebadge.exclamationmark"
        }
        return "externaldrive"
    }

    func start() {
        loadPersistedPreferences()
        UNUserNotificationCenter.current().delegate = notificationDelegate
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [logger] granted, error in
            if let error {
                logger.warning("Notification authorization request failed: \(error)")
            } else if !granted {
                logger.info("Notifications not authorized by the user")
            }
        }
        installHelperIfNeeded()
        Task { await recheckDependencies() }
        diskWatcher.start()
        watchTask = Task { [weak self] in
            guard let self else { return }
            for await event in diskWatcher.events {
                await self.handle(event)
            }
        }
    }

    private func loadPersistedPreferences() {
        let defaults = UserDefaults.standard
        if let value = defaults.object(forKey: PreferencesKey.autoRemountEnabled) as? Bool {
            autoRemountEnabled = value
        }
        if let value = defaults.object(forKey: PreferencesKey.notificationsEnabled) as? Bool {
            notificationsEnabled = value
        }
        ignoredVolumeUUIDs = Set(defaults.stringArray(forKey: PreferencesKey.ignoredVolumeUUIDs) ?? [])
    }

    func isIgnored(_ volume: NTFSVolume) -> Bool {
        guard let uuid = volume.volumeUUID else { return false }
        return ignoredVolumeUUIDs.contains(uuid)
    }

    /// No-op for volumes without a `volumeUUID` (rare for NTFS, but DiskArbitration
    /// doesn't guarantee one) — there's no stable identifier to remember them by.
    func setIgnored(_ ignored: Bool, for volume: NTFSVolume) {
        guard let uuid = volume.volumeUUID else { return }
        if ignored {
            ignoredVolumeUUIDs.insert(uuid)
        } else {
            ignoredVolumeUUIDs.remove(uuid)
        }
    }

    func stop() {
        watchTask?.cancel()
        diskWatcher.stop()
    }

    func recheckDependencies() async {
        dependencyStatus = await dependencyChecker.checkAll()
    }

    func retryMount(_ volume: NTFSVolume) {
        Task {
            let result = await mountManager.attemptRemount(volume)
            apply(result, to: volume)
        }
    }

    func eject(_ volume: NTFSVolume) {
        Task {
            _ = try? await ProcessRunner().run(
                executable: "/usr/sbin/diskutil",
                arguments: ["eject", volume.bsdName]
            )
        }
    }

    /// Registers the privileged LaunchDaemon that performs the actual NTFS
    /// mount as root (ntfs-3g refuses to mount as a regular user — see
    /// PrivilegedHelperMounter). A no-op once already registered; if it needs
    /// approval, `register()` still returns normally and the pending state
    /// shows up via DependencyChecker/DependencyWarningView instead of here.
    func installHelperIfNeeded() {
        let service = SMAppService.daemon(plistName: helperLaunchDaemonPlistName)
        guard service.status == .notRegistered || service.status == .notFound else { return }
        do {
            try service.register()
        } catch {
            logger.error("Could not register the privileged helper: \(error)")
        }
    }

    var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Could not change login item registration: \(error)")
        }
    }

    private func handle(_ event: DiskEvent) async {
        switch event {
        case .appeared(let volume):
            upsert(volume)
            guard autoRemountEnabled, !isIgnored(volume) else { return }
            if let result = await mountManager.handle(event) {
                apply(result, to: volume)
            }
        case .descriptionChanged(let volume):
            if volumes.firstIndex(where: { $0.bsdName == volume.bsdName }) == nil {
                volumes.append(volume)
            }
            guard autoRemountEnabled, !isIgnored(volume) else { return }
            if let result = await mountManager.handle(event) {
                apply(result, to: volume)
            }
        case .disappeared(let bsdName):
            volumes.removeAll { $0.bsdName == bsdName }
            _ = await mountManager.handle(event)
        }
    }

    private func apply(_ result: Result<NTFSVolume, MountError>, to volume: NTFSVolume) {
        switch result {
        case .success(let mounted):
            upsert(mounted)
            notify(title: mounted.volumeName, body: "Montado en lectura/escritura.")
        case .failure(let error):
            var updated = volume
            updated.mountState = .error(Self.describe(error))
            upsert(updated)
            if Self.isNotifiable(error) {
                notify(title: volume.volumeName, body: Self.describe(error))
            }
        }
    }

    /// Skips `.dependenciesNotReady` (already surfaced persistently via the
    /// "Dependencias faltantes" banner — repeating it per volume would just
    /// be noise) and `.operationAlreadyInProgress` (an internal dedup
    /// signal, not something the user did anything about).
    private static func isNotifiable(_ error: MountError) -> Bool {
        switch error {
        case .dependenciesNotReady, .operationAlreadyInProgress:
            return false
        case .volumeDirty, .unmountFailed, .mountFailed, .mountFailedAndFallbackFailed:
            return true
        }
    }

    private func notify(title: String, body: String) {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [logger] error in
            if let error {
                logger.warning("Failed to post notification: \(error)")
            }
        }
    }

    private func upsert(_ volume: NTFSVolume) {
        if let index = volumes.firstIndex(where: { $0.bsdName == volume.bsdName }) {
            volumes[index] = volume
        } else {
            volumes.append(volume)
        }
    }

    private static func describe(_ error: MountError) -> String {
        switch error {
        case .dependenciesNotReady:
            return "Faltan dependencias (macFUSE/ntfs-3g)"
        case .volumeDirty:
            return "Hibernación de Windows detectada — no se remonta en escritura"
        case .unmountFailed(let detail):
            return "No se pudo desmontar: \(detail)"
        case .mountFailed(let detail):
            return "No se pudo montar en escritura: \(detail)"
        case .mountFailedAndFallbackFailed:
            return "Error crítico: el volumen podría no estar accesible"
        case .operationAlreadyInProgress:
            return "Operación en curso"
        }
    }
}
