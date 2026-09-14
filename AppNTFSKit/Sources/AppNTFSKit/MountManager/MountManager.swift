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
    private let mountPointInspector: MountPointInspecting
    private let logger: AppLogger

    /// `statfs` type names that mean "one of ours" without containing `fuse`.
    ///
    /// Just the one, and it earns its place: every other name the backends
    /// produce (`macfuse`, `osxfuse`, `fuse-t`, and whatever the FSKit module
    /// reports) is caught by the substring rule below, so enumerating them was
    /// pure duplication of the check that follows.
    private static let nonFuseNamedFileSystemTypes: Set<String> = ["ntfs-3g"]

    /// Whether a `statfs` type name is one of ours.
    ///
    /// Matched loosely on purpose. The exact string depends on the backend —
    /// the kext reports `macfuse`, while the FSKit module registers itself as
    /// the "macFUSE (FSKit)" personality and its mounts have not been observed
    /// first-hand here (the FSKit extension could not be switched on during
    /// development, see README). Anything carrying `fuse` is therefore
    /// accepted rather than enumerated.
    ///
    /// The one string this must *not* match is the native read-only driver's,
    /// which is exactly `ntfs` — that is the state the pipeline is trying to
    /// replace, so treating it as success would report a read-only volume as
    /// read-write. It doesn't: `ntfs` contains neither `fuse` nor `ntfs-3g`.
    static func isFuseFileSystemType(_ type: String) -> Bool {
        let normalized = type.lowercased()
        return normalized.contains("fuse") || nonFuseNamedFileSystemTypes.contains(normalized)
    }

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
        mountPointInspector: MountPointInspecting = DefaultMountPointInspector(),
        logger: AppLogger = .shared
    ) {
        self.runner = runner
        self.dependencyChecker = dependencyChecker
        self.diskUtil = DiskUtilCommand(runner: runner)
        self.privilegedMounter = privilegedMounter
        self.mountPointInspector = mountPointInspector
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

    /// Confirms that a volume the app believes it mounted read-write still is,
    /// and re-runs the pipeline when it isn't. `nil` means the mount is fine
    /// and nothing was done.
    ///
    /// Waking from sleep is what this exists for. A FUSE mount can be gone
    /// afterwards — the drive powered down, the userspace daemon died — while
    /// DiskArbitration reports nothing at all: no `.appeared`, no
    /// `.descriptionChanged`. Nothing in the event-driven path ever fires, so
    /// the row goes on claiming read-write over a mountpoint that no longer
    /// resolves, and the first write the user attempts is the thing that tells
    /// them otherwise.
    public func revalidateReadWriteMount(_ volume: NTFSVolume) async -> Result<NTFSVolume, MountError>? {
        if let fileSystemType = mountPointInspector.fileSystemType(atPath: volume.mountPath),
           Self.isFuseFileSystemType(fileSystemType) {
            return nil
        }
        logger.warning("\(volume.bsdName) is no longer mounted read-write — re-running the pipeline")
        // This volume has been through the pipeline once, so `handledByUs`
        // holds it and the normal path would drop the attempt as a duplicate.
        // The suppression exists to stop a failure loop driven by our own disk
        // events; this call comes from a wake notification, not from one of
        // those events, so it is not what that guard is protecting against.
        handledByUs.remove(volume.bsdName)
        return await attemptRemount(volume, repairDirtyFlag: false)
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
        // Marked before the first `await` so a description-changed event that
        // races in while we're mid-pipeline is suppressed: every path below
        // the dependency gate touches the disk (probe, unmount,
        // restoreReadOnly) and would otherwise re-trigger this same method.
        // An explicit user "Reintentar" bypasses this guard since it calls
        // attemptRemount directly.
        handledByUs.insert(volume.bsdName)

        logger.info("Detected NTFS volume \(volume.volumeName) (\(volume.bsdName))")

        // Idempotency: if it's already mounted read-write through ntfs-3g
        // (the app restarted / relaunched at login while the volume stayed
        // put), don't tear down a working mount just to rebuild it. Skipped
        // for the explicit repair action, which the user asked for regardless.
        if !repairDirtyFlag,
           let fsType = mountPointInspector.fileSystemType(atPath: volume.mountPath),
           Self.isFuseFileSystemType(fsType) {
            logger.info("\(volume.bsdName) already mounted read-write via \(fsType) — nothing to do")
            var mounted = volume
            mounted.mountState = .readWrite
            return .success(mounted)
        }

        let status = await dependencyChecker.cachedStatus()
        guard status.isReady, let ntfs3gBinDirectory = status.ntfs3gBinDirectory else {
            logger.warning("Dependencies not ready for \(volume.bsdName): \(status)")
            // Nothing above touched the disk, so un-suppress this volume:
            // a later retry (a replug, or `AppCoordinator.recheckDependencies`
            // once the user installs what's missing) should actually run
            // rather than being silently dropped by the `handledByUs` guard.
            handledByUs.remove(volume.bsdName)
            return .failure(.dependenciesNotReady(status))
        }

        let ntfs3g = Ntfs3gCommand(runner: runner, binDirectory: ntfs3gBinDirectory)
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

        // Each backend gets a full attempt; the first one that actually ends
        // up mounted wins. On a machine with FSKit enabled that is the first
        // try and the kext is never touched — no Recovery Mode, no restart.
        var lastError = "no backend was attempted"
        for backend in status.mountBackends {
            guard let error = await mountFailureReason(
                volume, backend: backend, ntfs3g: ntfs3g, mounter: mounter
            ) else {
                var mounted = volume
                mounted.mountState = .readWrite
                logger.info("Mounted \(volume.volumeName) (\(volume.bsdName)) read-write via \(backend.rawValue)")
                return .success(mounted)
            }
            lastError = error
            logger.warning("\(backend.rawValue) backend failed for \(volume.bsdName): \(error)")
        }

        logger.error("every backend failed for \(volume.bsdName): \(lastError) — falling back to read-only")
        let annotated = Self.namingFullDiskAccessIfUnverified(lastError, status: status)
        let fallbackSucceeded = await restoreReadOnly(volume)
        return .failure(fallbackSucceeded
            ? .mountFailed(annotated)
            : .mountFailedAndFallbackFailed(mountError: annotated, fallbackError: "diskutil mount also failed"))
    }

    /// Adds Full Disk Access to the list of suspects when the checker could not
    /// rule it out.
    ///
    /// `fullDiskAccessGranted == nil` means the probe never ran — the helper
    /// wasn't reachable to be asked — so the app genuinely does not know
    /// whether the helper can open `/dev/rdisk*`. That is deliberately *not*
    /// enough to raise the warning banner (see `DependencyStatus.isReady`),
    /// because guessing wrong would send every user to System Settings for a
    /// permission they already granted. Once a mount has actually failed the
    /// balance flips: the unknown is now a live suspect and worth naming.
    ///
    /// It goes on its own line so `MountError.description` — which keeps only
    /// the first line — stays a one-liner fit for a notification, and the hint
    /// surfaces in the tooltip and the log alongside the full text.
    private static func namingFullDiskAccessIfUnverified(
        _ reason: String,
        status: DependencyStatus
    ) -> String {
        guard status.fullDiskAccessGranted == nil else { return reason }
        return """
            \(reason)
            No se pudo verificar el Acceso completo al disco del helper. Si el problema \
            persiste, revisá Ajustes del Sistema → Privacidad y seguridad → Acceso completo al disco.
            """
    }

    /// One mount attempt with one backend. `nil` means the volume really is
    /// mounted; anything else is the reason it isn't, so the caller can report
    /// whichever backend failed last.
    ///
    /// The result is confirmed against the mount table rather than the exit
    /// code, because `ntfs-3g`'s exit code cannot carry it: it daemonizes, and
    /// the parent returns 0 before the child knows whether the mount took.
    /// Verified directly — a mount that failed with "File system extension not
    /// enabled", and one attempted with no kext loaded at all, both exited 0
    /// and printed nothing to stderr. Trusting that alone would report a
    /// failed mount as a success, and would leave the FSKit-to-kext fallback
    /// below permanently unreachable.
    ///
    /// (macFUSE 5.4.0 changes this — its libfuse waits for the mount and exits
    /// with a status that reflects it, macfuse/macfuse#1178. The check stays
    /// regardless: it costs one `statfs`, and it is what makes the pipeline
    /// correct on the older macFUSE builds users already have installed.)
    private func mountFailureReason(
        _ volume: NTFSVolume,
        backend: FuseBackend,
        ntfs3g: Ntfs3gCommand,
        mounter: PrivilegedMounting
    ) async -> String? {
        let result: ProcessResult
        do {
            result = try await mounter.mountReadWrite(
                ntfs3gExecutablePath: ntfs3g.executablePath,
                devicePath: volume.blockDevicePath,
                mountPath: volume.mountPath,
                options: ntfs3g.mountOptions(volumeName: volume.volumeName, backend: backend)
            )
        } catch {
            return "\(error)"
        }

        guard result.succeeded else {
            return result.standardError.isEmpty
                ? "ntfs-3g exited with a failure status"
                : result.standardError
        }

        guard let fsType = mountPointInspector.fileSystemType(atPath: volume.mountPath) else {
            return "nothing is mounted at \(volume.mountPath) after ntfs-3g reported success"
        }
        guard Self.isFuseFileSystemType(fsType) else {
            return "\(volume.mountPath) is mounted as \(fsType), not a FUSE filesystem"
        }
        return nil
    }

    /// Never leave a volume unreachable after we've unmounted its native RO
    /// mount: if the ntfs-3g remount fails for any reason, put the native
    /// read-only mount back.
    @discardableResult
    private func restoreReadOnly(_ volume: NTFSVolume) async -> Bool {
        // Detached, so it does not inherit the caller's cancellation.
        //
        // Every call site reaches here *after* the native read-only mount has
        // already been torn down, and one of the ways to get here is the user
        // pressing cancel — which `ProcessRunner` implements by SIGTERMing the
        // child. If this inherited that cancellation it would die on its first
        // `diskutil` call and the volume would be left with no mount at all:
        // cancelling a remount would be strictly worse than letting it fail.
        let diskUtil = diskUtil
        let bsdName = volume.bsdName
        return await Task.detached {
            (try? await diskUtil.mount(bsdName: bsdName))?.succeeded ?? false
        }.value
    }

}
