import Foundation

/// Orchestrates the remount pipeline for NTFS volumes: dedup -> dependency gate
/// -> dirty-flag probe -> unmount native RO -> mount via ntfs-3g -> fallback to
/// RO on failure. An actor because DiskWatcher can emit several events for the
/// same device in quick succession and every step here must be serialized per
/// volume to avoid racing unmount/remount attempts against each other.
public actor MountManager {
    private let runner: ProcessRunning
    private let dependencyChecker: DependencyChecker
    private let diskUtil: DiskUtilCommand
    private let logger: AppLogger

    /// nil ⇒ falls back to mounting directly as the current user (only ever
    /// works in tests; `ntfs-3g` itself refuses unprivileged mounts in
    /// practice). Production wires in `PrivilegedHelperMounter`, which talks
    /// to the root LaunchDaemon via XPC — see AppNTFS/Helper/.
    private let privilegedMounter: PrivilegedMounting?

    /// bsdNames currently mid-pipeline; guards against overlapping attempts for
    /// the same device.
    private var inFlight: Set<String> = []

    /// bsdNames we've already run a remount attempt for, successful or not.
    /// Any of our own disk operations (the read-write mount on success, or
    /// `restoreReadOnly`'s native remount on failure) triggers a fresh
    /// DiskDescriptionChanged event for the same device — without this
    /// guard, a persistently-failing volume (e.g. a real "dirty" flag, or a
    /// genuinely broken filesystem) would loop forever: attempt → fail →
    /// restore read-only → new event → attempt again. Confirmed as an actual
    /// runaway loop on real hardware before this guard covered the failure
    /// path too (it originally only covered the success path).
    private var handledByUs: Set<String> = []

    public init(
        runner: ProcessRunning = ProcessRunner(),
        dependencyChecker: DependencyChecker = DependencyChecker(),
        privilegedMounter: PrivilegedMounting? = nil,
        logger: AppLogger = .shared
    ) {
        self.runner = runner
        self.dependencyChecker = dependencyChecker
        self.diskUtil = DiskUtilCommand(runner: runner)
        self.privilegedMounter = privilegedMounter
        self.logger = logger
    }

    /// Returns the outcome of a remount attempt, or nil when the event didn't
    /// trigger one (a disappearance, or a description-changed event for a
    /// device we've already run an attempt for — see `handledByUs`).
    @discardableResult
    public func handle(_ event: DiskEvent) async -> Result<NTFSVolume, MountError>? {
        switch event {
        case .appeared(let volume):
            return await attemptRemount(volume)
        case .descriptionChanged(let volume):
            guard !handledByUs.contains(volume.bsdName) else { return nil }
            return await attemptRemount(volume)
        case .disappeared(let bsdName):
            handledByUs.remove(bsdName)
            inFlight.remove(bsdName)
            return nil
        }
    }

    @discardableResult
    public func attemptRemount(_ volume: NTFSVolume) async -> Result<NTFSVolume, MountError> {
        await attemptRemount(volume, repairDirtyFlag: false)
    }

    /// Runs `ntfsfix` to clear the Windows dirty/hibernation flag, then
    /// attempts the normal read-write remount — the explicit,
    /// user-initiated counterpart to `attemptRemount` for the
    /// "Reparar y reintentar" UI action on a volume that previously failed
    /// with `.volumeDirty`. Deliberately never invoked automatically: a
    /// dirty flag can also mean genuine filesystem corruption rather than a
    /// normal Windows suspend/hibernate, so clearing it blind isn't safe as
    /// a default behavior — only as something the user explicitly asks for.
    @discardableResult
    public func fixAndRemount(_ volume: NTFSVolume) async -> Result<NTFSVolume, MountError> {
        await attemptRemount(volume, repairDirtyFlag: true)
    }

    private func attemptRemount(_ volume: NTFSVolume, repairDirtyFlag: Bool) async -> Result<NTFSVolume, MountError> {
        guard !inFlight.contains(volume.bsdName) else {
            return .failure(.operationAlreadyInProgress)
        }
        inFlight.insert(volume.bsdName)
        defer { inFlight.remove(volume.bsdName) }
        // Marked up front, not just on success: every path from here on
        // touches the disk (probe, unmount, restoreReadOnly) and would
        // otherwise re-trigger this same method via DiskArbitration's
        // description-changed event. An explicit user "Reintentar" bypasses
        // this guard entirely since it calls attemptRemount directly.
        handledByUs.insert(volume.bsdName)

        logger.info("Detected NTFS volume \(volume.volumeName) (\(volume.bsdName))")

        let status = await dependencyChecker.checkAll()
        guard status.isReady, let homebrewPrefix = status.homebrewPrefix else {
            logger.warning("Dependencies not ready for \(volume.bsdName): \(status)")
            return .failure(.dependenciesNotReady(status))
        }

        let ntfs3g = Ntfs3gCommand(runner: runner, homebrewPrefix: homebrewPrefix)
        let mounter = privilegedMounter ?? ntfs3g

        // Unmount before probing, not after: ntfs-3g.probe (and ntfsfix)
        // need exclusive access to the raw device and fail with "Resource
        // busy" on anything currently mounted — even our own native
        // read-only mount, even as root. That busy failure looks identical
        // to a real dirty flag from the probe's exit code alone, which
        // previously produced false "Hibernación de Windows" reports on a
        // genuinely clean volume (confirmed on real hardware: a manual
        // unmount-then-probe reported clean while probe-before-unmount
        // reported dirty for the same device back to back).
        do {
            let unmountResult = try await diskUtil.unmount(mountPath: volume.mountPath)
            guard unmountResult.succeeded else {
                logger.error("diskutil unmount failed for \(volume.bsdName): \(unmountResult.standardError)")
                return .failure(.unmountFailed(unmountResult.standardError))
            }
        } catch {
            logger.error("diskutil unmount threw for \(volume.bsdName): \(error)")
            return .failure(.unmountFailed("\(error)"))
        }

        if repairDirtyFlag {
            do {
                let fixResult = try await mounter.fix(
                    ntfsfixExecutablePath: ntfs3g.fixExecutablePath,
                    devicePath: volume.rawDevicePath
                )
                guard fixResult.succeeded else {
                    logger.error("ntfsfix failed for \(volume.bsdName): \(fixResult.standardError) — falling back to read-only")
                    await restoreReadOnly(volume)
                    return .failure(.mountFailed(fixResult.standardError))
                }
                logger.info("ntfsfix cleared the dirty/hibernation flag for \(volume.bsdName)")
            } catch {
                logger.error("ntfsfix threw for \(volume.bsdName): \(error) — falling back to read-only")
                await restoreReadOnly(volume)
                return .failure(.mountFailed("\(error)"))
            }
        }

        do {
            guard try await mounter.probeReadWrite(
                ntfs3gProbeExecutablePath: ntfs3g.probeExecutablePath,
                devicePath: volume.rawDevicePath
            ) else {
                logger.warning("Volume \(volume.bsdName) has the Windows dirty/hibernation flag set — leaving read-only")
                await restoreReadOnly(volume)
                return .failure(.volumeDirty)
            }
        } catch {
            logger.error("ntfs-3g.probe failed for \(volume.bsdName): \(error) — falling back to read-only")
            await restoreReadOnly(volume)
            return .failure(.mountFailed("\(error)"))
        }

        let mountResult: ProcessResult
        do {
            mountResult = try await mounter.mountReadWrite(
                ntfs3gExecutablePath: ntfs3g.executablePath,
                devicePath: volume.blockDevicePath,
                mountPath: volume.mountPath,
                options: ntfs3g.mountOptions(volumeName: volume.volumeName)
            )
        } catch {
            logger.error("mount_ntfs-3g threw for \(volume.bsdName): \(error) — falling back to read-only")
            let fallbackSucceeded = await restoreReadOnly(volume)
            return .failure(fallbackSucceeded
                ? .mountFailed("\(error)")
                : .mountFailedAndFallbackFailed(mountError: "\(error)", fallbackError: "diskutil mount also failed"))
        }

        guard mountResult.succeeded else {
            logger.error("mount_ntfs-3g failed for \(volume.bsdName): \(mountResult.standardError) — falling back to read-only")
            let fallbackSucceeded = await restoreReadOnly(volume)
            return .failure(fallbackSucceeded
                ? .mountFailed(mountResult.standardError)
                : .mountFailedAndFallbackFailed(mountError: mountResult.standardError, fallbackError: "diskutil mount also failed"))
        }

        var mounted = volume
        mounted.mountState = .readWrite
        logger.info("Mounted \(volume.volumeName) (\(volume.bsdName)) read-write")
        return .success(mounted)
    }

    /// Never leave a volume unreachable after we've unmounted its native RO
    /// mount: if the ntfs-3g remount fails for any reason, put the native
    /// read-only mount back.
    @discardableResult
    private func restoreReadOnly(_ volume: NTFSVolume) async -> Bool {
        (try? await diskUtil.mount(bsdName: volume.bsdName))?.succeeded ?? false
    }

}
