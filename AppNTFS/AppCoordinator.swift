import AppKit
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

/// Top-level (file-scope) functions, not methods on `AppCoordinator` — a
/// closure/method written lexically inside a @MainActor type gets inferred
/// as MainActor-isolated even when it only captures Sendable values, but
/// UNUserNotificationCenter always calls its completion handlers back on
/// its own background queue. That mismatch crashes at runtime with SIGTRAP
/// (confirmed via a real crash report from a release build —
/// `dispatch_assert_queue_fail` / `swift_task_checkIsolatedSwift` inside
/// "closure #1 in AppCoordinator.start()"). Top-level functions have no
/// enclosing actor context at all, so there's nothing to infer — and using
/// `AppLogger.shared` directly avoids needing to capture `self` (which
/// isn't `Sendable`) to reach the instance's `logger` property.
private func handleNotificationAuthorization(granted: Bool, error: Error?) {
    if let error {
        AppLogger.shared.warning("Notification authorization request failed: \(error)")
    } else if !granted {
        AppLogger.shared.info("Notifications not authorized by the user")
    }
}

private func handleNotificationPosted(_ error: Error?) {
    if let error {
        AppLogger.shared.warning("Failed to post notification: \(error)")
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
    private let updateChecker = UpdateChecker()
    private var watchTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    /// The in-flight mount pipeline per `bsdName`, so the UI can cancel one
    /// drive without touching the others. Kept as a stored property because
    /// `@Observable` tracks it — the cancel button appears and disappears off
    /// this dictionary.
    private var operationTasks: [String: Task<Void, Never>] = [:]

    /// The menu-bar icon used to answer one question ("are the dependencies
    /// installed?") and then show the same drive glyph forever. It now answers
    /// the one the user actually has while the app is running — what is
    /// happening to my drives right now — without opening the menu.
    var statusSymbolName: String {
        guard let dependencyStatus, dependencyStatus.isReady else {
            return "externaldrive.trianglebadge.exclamationmark"
        }
        if volumes.contains(where: { $0.mountState == .mounting }) {
            return "externaldrive.badge.plus"
        }
        if volumes.contains(where: { if case .error = $0.mountState { return true } else { return false } }) {
            return "externaldrive.badge.exclamationmark"
        }
        if volumes.contains(where: { $0.mountState == .readWrite }) {
            return "externaldrive.badge.checkmark"
        }
        return "externaldrive"
    }

    func start() {
        loadPersistedPreferences()
        UNUserNotificationCenter.current().delegate = notificationDelegate
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound],
            completionHandler: handleNotificationAuthorization
        )
        installHelperIfNeeded()
        Task { await recheckDependencies() }
        diskWatcher.start()
        watchTask = Task { [weak self] in
            guard let self else { return }
            for await event in diskWatcher.events {
                await self.handle(event)
            }
        }
        observeWake()
        checkForUpdates(userInitiated: false)
    }

    /// DiskArbitration is silent about what sleep does to a FUSE mount, so the
    /// wake notification is the only hook there is — see
    /// `MountManager.revalidateReadWriteMount`.
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.revalidateMountsAfterWake() }
        }
    }

    private func revalidateMountsAfterWake() {
        guard autoRemountEnabled else { return }
        logger.info("System woke — revalidating read-write mounts")
        for volume in volumes where volume.mountState == .readWrite && !isIgnored(volume) {
            // `showProgress: false` — the overwhelmingly common outcome is
            // "still mounted, nothing to do", and flashing every row to
            // "Montando…" on every single wake would be a lie most of the time.
            startOperation(on: volume, replacingAnyCurrent: false, showProgress: false) { manager in
                await manager.revalidateReadWriteMount(volume)
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
        for task in operationTasks.values { task.cancel() }
        operationTasks.removeAll()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        diskWatcher.stop()
    }

    /// Whether this volume has a mount attempt running that the user can call
    /// off — drives the per-row "Cancelar" button.
    func isOperating(_ volume: NTFSVolume) -> Bool {
        operationTasks[volume.bsdName] != nil
    }

    /// Real cancellation, not just "stop listening": `ProcessRunner` installs a
    /// cancellation handler that SIGTERMs whatever child is running, so a
    /// `ntfs-3g` grinding away on a bad drive actually stops. The read-only
    /// fallback inside `MountManager` is shielded from it and still runs, so
    /// the volume is left mounted read-only rather than not mounted at all —
    /// which is why the row goes back to `.readOnly` here.
    func cancelOperation(_ volume: NTFSVolume) {
        guard let task = operationTasks.removeValue(forKey: volume.bsdName) else { return }
        logger.info("User cancelled the pending operation for \(volume.bsdName)")
        task.cancel()
        var updated = volume
        updated.mountState = .readOnly
        upsert(updated)
    }

    /// Starts one tracked, cancellable attempt and publishes its outcome.
    ///
    /// `replacingAnyCurrent` distinguishes the two kinds of caller. A user
    /// pressing "Reintentar" expresses a newer intent than whatever is already
    /// running for that drive, so the old attempt is called off and this one
    /// takes over — `MountManager`'s own `inFlight` guard would otherwise
    /// reject the *new* one with `.operationAlreadyInProgress`, which is the
    /// wrong way round for a button press. Automatic callers (a disk event, a
    /// wake revalidation) pass `false`: they are speculative, and must not
    /// cancel work the user asked for.
    @discardableResult
    private func startOperation(
        on volume: NTFSVolume,
        replacingAnyCurrent: Bool,
        showProgress: Bool = true,
        _ body: @escaping @Sendable (MountManager) async -> Result<NTFSVolume, MountError>?
    ) -> Task<Void, Never> {
        let previous = replacingAnyCurrent ? operationTasks.removeValue(forKey: volume.bsdName) : nil
        previous?.cancel()
        if showProgress {
            markMounting(volume)
        }

        let bsdName = volume.bsdName
        let manager = mountManager
        let task = Task { [weak self] in
            // Wait for the attempt we just called off to finish unwinding.
            // Cancelling the Swift task doesn't release `MountManager`'s
            // per-device `inFlight` slot — that happens when the pipeline
            // actually returns — so starting immediately would get this
            // replacement rejected with `.operationAlreadyInProgress`, which
            // `apply` deliberately ignores, and the row would sit on
            // "Montando…" with nothing left running to ever update it.
            // `markMounting` above already ran, so the UI reacts at once.
            await previous?.value
            let result = await body(manager)
            guard let self else { return }
            // A cancelled task must not touch the dictionary: by the time it
            // gets here the entry may already belong to its replacement, and
            // clearing that would strand the new attempt with no cancel button.
            // `cancelOperation` / `startOperation` remove the entry up front.
            guard !Task.isCancelled else { return }
            operationTasks[bsdName] = nil
            if let result {
                apply(result, to: volume)
            } else if showProgress {
                // The pipeline declined to run (nothing to do). Without this
                // the optimistic "Montando…" above would never be replaced.
                refreshRowAfterNoOp(volume)
            }
        }
        operationTasks[bsdName] = task
        return task
    }

    /// Undoes an optimistic `markMounting` for an attempt that turned out to be
    /// a no-op, without inventing a state: `volume` is the caller's pre-attempt
    /// snapshot, so whatever the row said then is still what's true now.
    private func refreshRowAfterNoOp(_ volume: NTFSVolume) {
        guard let index = volumes.firstIndex(where: { $0.bsdName == volume.bsdName }),
              volumes[index].mountState == .mounting else { return }
        // `.readOnly` only as the floor, for the pathological case where the
        // snapshot itself was mid-attempt — restoring `.mounting` would leave
        // the row exactly as stuck as doing nothing.
        volumes[index].mountState = volume.mountState == .mounting ? .readOnly : volume.mountState
    }

    func recheckDependencies() async {
        let wasReady = dependencyStatus?.isReady ?? false
        dependencyStatus = await dependencyChecker.checkAll()

        // When dependencies just went from missing to ready, drive the
        // volumes that failed for exactly that reason — otherwise the user
        // would have to physically replug each drive after installing
        // macFUSE / approving the helper.
        guard !wasReady, dependencyStatus?.isReady == true, autoRemountEnabled else { return }
        for volume in volumes where Self.failedForMissingDependencies(volume) && !isIgnored(volume) {
            await startOperation(on: volume, replacingAnyCurrent: false) { manager in
                await manager.attemptRemount(volume)
            }.value
        }
    }

    private static func failedForMissingDependencies(_ volume: NTFSVolume) -> Bool {
        if case .error(.dependenciesNotReady) = volume.mountState { return true }
        return false
    }

    func retryMount(_ volume: NTFSVolume) {
        startOperation(on: volume, replacingAnyCurrent: true) { manager in
            await manager.attemptRemount(volume)
        }
    }

    /// The "Reparar y reintentar" action — explicit, one click, only ever
    /// user-initiated (see `MountManager.fixAndRemount`'s doc comment for
    /// why this is never automatic).
    func fixAndRetryMount(_ volume: NTFSVolume) {
        startOperation(on: volume, replacingAnyCurrent: true) { manager in
            await manager.fixAndRemount(volume)
        }
    }

    /// Both `diskutil` calls are now checked. They used to be `_ = try?`, which
    /// meant ejecting a drive macOS refused to unmount looked exactly like
    /// ejecting one it did: no notification, no log line, and a row that
    /// vanished on the next event or didn't. The user's next move after
    /// clicking "Expulsar" is to physically unplug the drive, so "it didn't
    /// work" is not a detail worth swallowing.
    func eject(_ volume: NTFSVolume) {
        Task { [weak self] in
            guard let self else { return }
            let runner = ProcessRunner()

            // Unmount first: `diskutil eject` alone can leave an ntfs-3g /
            // FUSE mount behind. Force-unmount the mountpoint, then eject the
            // whole device.
            do {
                let unmount = try await runner.run(
                    executable: "/usr/sbin/diskutil",
                    arguments: ["unmount", "force", volume.mountPath]
                )
                // A failed unmount is only fatal if something is *still*
                // mounted there. It also fails for a volume that was never
                // mounted in the first place — a drive sitting in `.error`
                // after a botched remount is exactly that, and refusing to
                // eject it would strand the one drive most likely to need it.
                if !unmount.succeeded, isStillMounted(volume.mountPath) {
                    reportEjectFailure(volume, reason: unmount.standardError)
                    return
                }

                let eject = try await runner.run(
                    executable: "/usr/sbin/diskutil",
                    arguments: ["eject", volume.bsdName]
                )
                guard eject.succeeded else {
                    reportEjectFailure(volume, reason: eject.standardError)
                    return
                }
                logger.info("Ejected \(volume.volumeName) (\(volume.bsdName))")
            } catch {
                reportEjectFailure(volume, reason: "\(error)")
            }
        }
    }

    private func isStillMounted(_ mountPath: String) -> Bool {
        guard !mountPath.isEmpty else { return false }
        return DefaultMountPointInspector().fileSystemType(atPath: mountPath) != nil
    }

    private func reportEjectFailure(_ volume: NTFSVolume, reason: String) {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.error("Eject failed for \(volume.bsdName): \(trimmed)")
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? ""
        notify(
            title: volume.volumeName,
            body: firstLine.isEmpty
                ? "No se pudo expulsar el disco."
                : "No se pudo expulsar el disco: \(firstLine)"
        )
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

    /// A stored snapshot, not a computed read of `SMAppService.mainApp.status`
    /// — @Observable only tracks changes to stored properties, so a Toggle
    /// bound to a live system-state read never sees a reason to re-render
    /// after `setLaunchAtLogin` runs (confirmed: the toggle looked
    /// completely unresponsive even though registration itself was fine).
    private(set) var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = enabled
        } catch {
            logger.error("Could not change login item registration: \(error)")
        }
    }

    /// Re-syncs the stored snapshot with the real system state — call when a
    /// view showing the toggle appears, since the user can also change the
    /// login-item registration directly in System Settings while the app runs.
    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Updates

    /// The newer release, once a check has found one. `nil` means "current, or
    /// not checked yet" — the menu entry stays out of the way either way.
    private(set) var availableUpdate: ReleaseInfo?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// `userInitiated` only changes how loudly a failure is reported: a
    /// background check that can't reach GitHub is not worth a notification,
    /// but a user who clicked "Buscar actualizaciones" is owed an answer.
    func checkForUpdates(userInitiated: Bool) {
        let version = currentVersion
        Task { [weak self] in
            guard let self else { return }
            do {
                let update = try await updateChecker.availableUpdate(currentVersion: version)
                availableUpdate = update
                if let update {
                    logger.info("Update available: \(update.version) (running \(version))")
                } else if userInitiated {
                    notify(title: "AppNTFS \(version)", body: "Ya tenés la última versión.")
                }
            } catch {
                logger.warning("Update check failed: \(error)")
                if userInitiated {
                    notify(title: "AppNTFS", body: "\(error)")
                }
            }
        }
    }

    func openReleasePage() {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.open(update.pageURL)
    }

    private func handle(_ event: DiskEvent) async {
        switch event {
        case .appeared(let volume):
            upsert(volume)
            guard autoRemountEnabled, !isIgnored(volume) else { return }
            // `.appeared` always runs an attempt (never returns nil), so
            // showing "Montando…" here can't get stuck.
            await startOperation(on: volume, replacingAnyCurrent: false) { manager in
                await manager.handle(event)
            }.value
        case .descriptionChanged(let volume):
            mergeDescription(volume)
            guard autoRemountEnabled, !isIgnored(volume) else { return }
            // No `markMounting` here: `handle` may short-circuit to nil for a
            // device we've already acted on, which would leave the row stuck.
            await startOperation(
                on: volume, replacingAnyCurrent: false, showProgress: false
            ) { manager in
                await manager.handle(event)
            }.value
        case .disappeared(let bsdName):
            volumes.removeAll { $0.bsdName == bsdName }
            // The drive is gone; anything still running against it is working
            // on a device that no longer exists.
            operationTasks.removeValue(forKey: bsdName)?.cancel()
            _ = await mountManager.handle(event)
        }
    }

    /// Folds a `.descriptionChanged` event into the stored row: their facts,
    /// our state.
    ///
    /// DiskArbitration re-reports the volume when something about it changes —
    /// it got a name, macOS mounted it somewhere — but knows nothing about what
    /// this app has been doing with it, so the event's `mountState` is always
    /// the default. Storing it wholesale would wipe a "Montando…" or an error
    /// the user hasn't read yet; the previous behaviour of ignoring the event
    /// entirely for known devices left the row showing a stale name and
    /// mountpoint for as long as the drive stayed plugged in — most visibly for
    /// a volume that appears unnamed and is labelled a moment later.
    private func mergeDescription(_ volume: NTFSVolume) {
        guard let index = volumes.firstIndex(where: { $0.bsdName == volume.bsdName }) else {
            volumes.append(volume)
            return
        }
        var merged = volume
        merged.mountState = volumes[index].mountState
        volumes[index] = merged
    }

    private func apply(_ result: Result<NTFSVolume, MountError>, to volume: NTFSVolume) {
        switch result {
        case .success(let mounted):
            upsert(mounted)
            notify(title: mounted.volumeName, body: "Montado en lectura/escritura.")
        case .failure(.operationAlreadyInProgress):
            // Another attempt for this device is mid-pipeline and will publish
            // the real outcome — don't stomp the row with a transient error.
            break
        case .failure(let error):
            var updated = volume
            updated.mountState = .error(error)
            upsert(updated)
            if Self.isNotifiable(error) {
                notify(title: volume.volumeName, body: error.description)
            }
        }
    }

    /// Optimistic "Montando…" feedback while an attempt runs. Only used on
    /// paths guaranteed to reach `apply` afterwards.
    private func markMounting(_ volume: NTFSVolume) {
        var updated = volume
        updated.mountState = .mounting
        upsert(updated)
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
        UNUserNotificationCenter.current().add(request, withCompletionHandler: handleNotificationPosted)
    }

    private func upsert(_ volume: NTFSVolume) {
        if let index = volumes.firstIndex(where: { $0.bsdName == volume.bsdName }) {
            volumes[index] = volume
        } else {
            volumes.append(volume)
        }
    }

}
