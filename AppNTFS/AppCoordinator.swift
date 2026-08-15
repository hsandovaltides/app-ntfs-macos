import AppNTFSKit
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppCoordinator {
    private(set) var volumes: [NTFSVolume] = []
    private(set) var dependencyStatus: DependencyStatus?
    var autoRemountEnabled = true

    let logger = AppLogger.shared

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
            guard autoRemountEnabled else { return }
            if let result = await mountManager.handle(event) {
                apply(result, to: volume)
            }
        case .descriptionChanged(let volume):
            if volumes.firstIndex(where: { $0.bsdName == volume.bsdName }) == nil {
                volumes.append(volume)
            }
            guard autoRemountEnabled else { return }
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
        case .failure(let error):
            var updated = volume
            updated.mountState = .error(Self.describe(error))
            upsert(updated)
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
