import Testing
@testable import AppNTFSKit

@Suite("MountManager")
struct MountManagerTests {
    private static let homebrewPrefix = "/opt/homebrew"
    private static let ntfs3gBin = "\(homebrewPrefix)/opt/ntfs-3g-mac/bin/ntfs-3g"
    private static let ntfs3gProbe = "\(homebrewPrefix)/opt/ntfs-3g-mac/bin/ntfs-3g.probe"
    private static let ntfsfix = "\(homebrewPrefix)/opt/ntfs-3g-mac/bin/ntfsfix"
    private static let diskutil = "/usr/sbin/diskutil"

    private static let volume = NTFSVolume(
        bsdName: "disk4s1",
        volumeName: "MyDrive",
        volumeUUID: nil,
        mountPath: "/tmp/AppNTFSKitTests-MyDrive"
    )

    private func readyFileSystem() -> FakeFileSystemProbe {
        FakeFileSystemProbe(
            existingPaths: ["\(Self.homebrewPrefix)/Caskroom/macfuse"],
            executablePaths: ["\(Self.homebrewPrefix)/bin/brew", Self.ntfs3gBin]
        )
    }

    private func readyRunner(overrides: [String: ProcessResult] = [:]) -> FakeProcessRunner {
        var responses: [String: ProcessResult] = [
            "/usr/bin/systemextensionsctl": ProcessResult(
                exitCode: 0, standardOutput: SampleSystemExtensionsOutput.macFUSEApproved, standardError: ""
            ),
            Self.ntfs3gProbe: ProcessResult(exitCode: 0, standardOutput: "", standardError: ""),
            Self.ntfsfix: ProcessResult(exitCode: 0, standardOutput: "", standardError: ""),
            Self.diskutil: ProcessResult(exitCode: 0, standardOutput: "", standardError: ""),
            Self.ntfs3gBin: ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        ]
        overrides.forEach { responses[$0] = $1 }
        return FakeProcessRunner(responses: responses)
    }

    @Test("Full success pipeline mounts the volume read-write")
    func successfulRemount() async throws {
        let runner = readyRunner()
        let manager = MountManager(
            runner: runner,
            dependencyChecker: DependencyChecker(
                runner: runner,
                fileSystem: readyFileSystem(),
                helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedAndApproved)
            ),
            // Nothing mounted when the pipeline starts, ntfs-3g mounted by the
            // time it verifies. The verification is not optional: ntfs-3g
            // daemonizes and exits 0 even when the mount failed, so the mount
            // table is the only thing that can tell the two apart.
            mountPointInspector: .mountedAfterMounting(Self.volume.mountPath),
            logger: AppLogger()
        )

        let result = await manager.attemptRemount(Self.volume)

        let mounted = try result.get()
        #expect(mounted.mountState == .readWrite)

        let executed = await runner.calls.map(\.executable)
        #expect(executed.contains(Self.ntfs3gProbe))
        #expect(executed.contains(Self.diskutil))
        #expect(executed.contains(Self.ntfs3gBin))
    }

    @Test("Refuses to touch the volume when dependencies aren't ready")
    func dependenciesNotReady() async {
        let runner = FakeProcessRunner()
        let manager = MountManager(
            runner: runner,
            dependencyChecker: DependencyChecker(
                runner: runner,
                fileSystem: FakeFileSystemProbe(),
                helperStatusProbe: FakeHelperServiceStatusProbe(state: .notInstalled)
            ),
            logger: AppLogger()
        )

        let result = await manager.attemptRemount(Self.volume)

        guard case .failure(.dependenciesNotReady) = result else {
            Issue.record("Expected .dependenciesNotReady, got \(result)")
            return
        }
        #expect(await runner.calls.isEmpty)
    }

    @Test("Skips the whole pipeline when the volume is already ntfs-3g mounted")
    func alreadyMountedReadWriteIsANoOp() async throws {
        let runner = readyRunner()
        let manager = MountManager(
            runner: runner,
            dependencyChecker: DependencyChecker(
                runner: runner,
                fileSystem: readyFileSystem(),
                helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedAndApproved)
            ),
            mountPointInspector: FakeMountPointInspector(typesByPath: [Self.volume.mountPath: "macfuse"]),
            logger: AppLogger()
        )

        let result = await manager.attemptRemount(Self.volume)

        #expect(try result.get().mountState == .readWrite)
        #expect(await runner.calls.isEmpty)
    }

    @Test("The explicit repair action still runs even if something is mounted there")
    func repairIgnoresAlreadyMounted() async {
        let runner = readyRunner()
        let manager = MountManager(
            runner: runner,
            dependencyChecker: DependencyChecker(
                runner: runner,
                fileSystem: readyFileSystem(),
                helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedAndApproved)
            ),
            mountPointInspector: FakeMountPointInspector(typesByPath: [Self.volume.mountPath: "macfuse"]),
            logger: AppLogger()
        )

        _ = await manager.fixAndRemount(Self.volume)

        #expect(await runner.calls.contains { $0.executable == Self.ntfsfix })
    }

    @Test("A dependencies-not-ready failure doesn't suppress a later retry")
    func dependenciesNotReadyDoesNotSuppressRetry() async {
        let runner = FakeProcessRunner()
        let manager = MountManager(
            runner: runner,
            dependencyChecker: DependencyChecker(
                runner: runner,
                fileSystem: FakeFileSystemProbe(),
                helperStatusProbe: FakeHelperServiceStatusProbe(state: .notInstalled)
            ),
            logger: AppLogger()
        )

        let first = await manager.handle(.appeared(Self.volume))
        guard case .failure(.dependenciesNotReady) = first else {
            Issue.record("Expected .dependenciesNotReady, got \(String(describing: first))")
            return
        }

        // Unlike a real mount failure, this volume was never added to
        // `handledByUs` (nothing touched the disk), so a subsequent event
        // must be allowed to try again rather than returning nil.
        let second = await manager.handle(.descriptionChanged(Self.volume))
        guard case .failure(.dependenciesNotReady) = second else {
            Issue.record("Expected the retry to run and fail again, got \(String(describing: second))")
            return
        }
    }

    @Test("Leaves a dirty (Windows-hibernated) volume read-only, restored after probing")
    func dirtyVolumeIsRestoredReadOnly() async {
        let runner = readyRunner(overrides: [
            Self.ntfs3gProbe: ProcessResult(exitCode: 1, standardOutput: "", standardError: "dirty")
        ])
        let manager = MountManager(
            runner: runner,
            dependencyChecker: DependencyChecker(
                runner: runner,
                fileSystem: readyFileSystem(),
                helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedAndApproved)
            ),
            logger: AppLogger()
        )

        let result = await manager.attemptRemount(Self.volume)

        guard case .failure(.volumeDirty) = result else {
            Issue.record("Expected .volumeDirty, got \(result)")
            return
        }
        // ntfs-3g.probe needs the volume unmounted first (see MountManager's
        // doc comment), so diskutil unmount/mount both still run — only the
        // actual read-write mount (ntfs-3g itself) must never be invoked.
        let executed = await runner.calls.map(\.executable)
        #expect(executed.filter { $0 == Self.diskutil }.count == 2)
        #expect(executed.contains(Self.ntfs3gBin) == false)
    }

    @Test("A failed attempt doesn't loop on its own restoreReadOnly-triggered event")
    func failedAttemptDoesNotLoop() async {
        let runner = readyRunner(overrides: [
            Self.ntfs3gProbe: ProcessResult(exitCode: 1, standardOutput: "", standardError: "dirty")
        ])
        let manager = MountManager(
            runner: runner,
            dependencyChecker: DependencyChecker(
                runner: runner,
                fileSystem: readyFileSystem(),
                helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedAndApproved)
            ),
            logger: AppLogger()
        )

        let first = await manager.handle(.appeared(Self.volume))
        guard case .failure(.volumeDirty) = first else {
            Issue.record("Expected first attempt to fail with .volumeDirty, got \(String(describing: first))")
            return
        }

        // Simulates the DiskDescriptionChanged event that restoreReadOnly's
        // own `diskutil mount` triggers — without the fix this would re-run
        // the whole pipeline indefinitely.
        let second = await manager.handle(.descriptionChanged(Self.volume))
        #expect(second == nil)

        let probeCallCount = await runner.calls.filter { $0.executable == Self.ntfs3gProbe }.count
        #expect(probeCallCount == 1)
    }

    @Test("fixAndRemount clears the dirty flag via ntfsfix, then mounts read-write")
    func fixAndRemountSucceeds() async throws {
        let runner = readyRunner()
        let manager = MountManager(
            runner: runner,
            dependencyChecker: DependencyChecker(
                runner: runner,
                fileSystem: readyFileSystem(),
                helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedAndApproved)
            ),
            // The repair path skips the "already mounted?" check entirely, so
            // the only stat here is the post-mount verification.
            mountPointInspector: FakeMountPointInspector(
                typesByPath: [Self.volume.mountPath: "macfuse"]
            ),
            logger: AppLogger()
        )

        let result = await manager.fixAndRemount(Self.volume)

        let mounted = try result.get()
        #expect(mounted.mountState == .readWrite)

        let executed = await runner.calls.map(\.executable)
        #expect(executed.contains(Self.ntfsfix))
        #expect(executed.contains(Self.ntfs3gProbe))
        #expect(executed.contains(Self.ntfs3gBin))
    }

    @Test("fixAndRemount falls back to read-only when ntfsfix itself fails")
    func fixAndRemountFailure() async {
        let runner = readyRunner(overrides: [
            Self.ntfsfix: ProcessResult(exitCode: 1, standardOutput: "", standardError: "still broken")
        ])
        let manager = MountManager(
            runner: runner,
            dependencyChecker: DependencyChecker(
                runner: runner,
                fileSystem: readyFileSystem(),
                helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedAndApproved)
            ),
            logger: AppLogger()
        )

        let result = await manager.fixAndRemount(Self.volume)

        guard case .failure(.mountFailed) = result else {
            Issue.record("Expected .mountFailed, got \(result)")
            return
        }
        let executed = await runner.calls.map(\.executable)
        #expect(executed.contains(Self.ntfs3gProbe) == false)
        #expect(executed.contains(Self.ntfs3gBin) == false)
    }

    @Test("Falls back to a native read-only remount when mount_ntfs-3g fails")
    func mountFailureFallsBackToReadOnly() async {
        let runner = readyRunner(overrides: [
            Self.ntfs3gBin: ProcessResult(exitCode: 1, standardOutput: "", standardError: "boom")
        ])
        let manager = MountManager(
            runner: runner,
            dependencyChecker: DependencyChecker(
                runner: runner,
                fileSystem: readyFileSystem(),
                helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedAndApproved)
            ),
            logger: AppLogger()
        )

        let result = await manager.attemptRemount(Self.volume)

        guard case .failure(.mountFailed) = result else {
            Issue.record("Expected .mountFailed (with successful RO fallback), got \(result)")
            return
        }
        let diskutilCalls = await runner.calls.filter { $0.executable == Self.diskutil }
        #expect(diskutilCalls.count == 2)
    }

    @Test("A mount that exits 0 without mounting anything is treated as a failure")
    func exitCodeZeroIsNotEnough() async {
        // ntfs-3g daemonizes: the parent exits 0 before the child knows
        // whether the mount took, so a mount that failed outright still
        // reports success. Measured directly — a mount rejected with "File
        // system extension not enabled" exited 0 with an empty stderr. Only
        // the mount table can tell the two apart.
        let runner = readyRunner()
        let manager = MountManager(
            runner: runner,
            dependencyChecker: DependencyChecker(
                runner: runner,
                fileSystem: readyFileSystem(),
                helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedAndApproved)
            ),
            // Nothing at the mount path, before or after.
            mountPointInspector: FakeMountPointInspector(),
            logger: AppLogger()
        )

        let result = await manager.attemptRemount(Self.volume)

        guard case .failure(.mountFailed) = result else {
            Issue.record("Expected .mountFailed despite ntfs-3g exiting 0, got \(result)")
            return
        }
        // And the volume was handed back to the native read-only driver
        // rather than left unmounted.
        let diskutilCalls = await runner.calls.filter { $0.executable == Self.diskutil }
        #expect(diskutilCalls.count == 2)
    }

    @Test("A volume mounted as native read-only ntfs doesn't count as mounted")
    func nativeReadOnlyIsNotASuccessfulMount() async {
        let runner = readyRunner()
        let manager = MountManager(
            runner: runner,
            dependencyChecker: DependencyChecker(
                runner: runner,
                fileSystem: readyFileSystem(),
                helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedAndApproved)
            ),
            // `ntfs` is the native read-only driver — the state the pipeline
            // exists to replace. Accepting it would report a read-only volume
            // to the user as read-write.
            mountPointInspector: FakeMountPointInspector(
                sequencesByPath: [Self.volume.mountPath: [nil, "ntfs"]]
            ),
            logger: AppLogger()
        )

        let result = await manager.attemptRemount(Self.volume)

        guard case .failure(.mountFailed) = result else {
            Issue.record("Expected .mountFailed for a native ntfs mount, got \(result)")
            return
        }
    }

    @Test("FSKit is tried first and the kext takes over when it doesn't mount")
    func fallsBackFromFSKitToKext() async {
        let fskitExtension =
            "\(FuseBackendAvailability.macFUSEExtensionsDirectory)/\(FuseBackendAvailability.macFUSEFSKitExtensionName)"
        let fileSystem = FakeFileSystemProbe(
            existingPaths: ["\(Self.homebrewPrefix)/Caskroom/macfuse", fskitExtension],
            executablePaths: ["\(Self.homebrewPrefix)/bin/brew", Self.ntfs3gBin]
        )
        let runner = readyRunner()
        let manager = MountManager(
            runner: runner,
            dependencyChecker: DependencyChecker(
                runner: runner,
                fileSystem: fileSystem,
                helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedAndApproved),
                operatingSystemIsAtLeast: { _ in true }
            ),
            // Nothing mounted at the start; still nothing after the FSKit
            // attempt (the extension is present but switched off — the exact
            // situation this fallback exists for); mounted after the kext one.
            mountPointInspector: FakeMountPointInspector(
                sequencesByPath: [Self.volume.mountPath: [nil, nil, "macfuse"]]
            ),
            logger: AppLogger()
        )

        let result = await manager.attemptRemount(Self.volume)

        guard case .success(let mounted) = result else {
            Issue.record("Expected the kext attempt to succeed, got \(result)")
            return
        }
        #expect(mounted.mountState == .readWrite)

        let mountCalls = await runner.calls.filter { $0.executable == Self.ntfs3gBin }
        #expect(mountCalls.count == 2)
        #expect(mountCalls.first?.arguments.contains { $0.contains("backend=fskit") } == true)
        #expect(mountCalls.last?.arguments.contains { $0.contains("backend=") } == false)
    }

    @Test("The kext is the only attempt when FSKit isn't available")
    func kextOnlyWithoutFSKit() async {
        let runner = readyRunner()
        let manager = MountManager(
            runner: runner,
            dependencyChecker: DependencyChecker(
                runner: runner,
                fileSystem: readyFileSystem(),
                helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedAndApproved)
            ),
            mountPointInspector: .mountedAfterMounting(Self.volume.mountPath),
            logger: AppLogger()
        )

        _ = await manager.attemptRemount(Self.volume)

        let mountCalls = await runner.calls.filter { $0.executable == Self.ntfs3gBin }
        #expect(mountCalls.count == 1)
        #expect(mountCalls.first?.arguments.contains { $0.contains("backend=") } == false)
    }

    @Test("Only FUSE mounts count as a successful read-write mount")
    func fuseFileSystemTypeRecognition() {
        #expect(MountManager.isFuseFileSystemType("macfuse"))
        #expect(MountManager.isFuseFileSystemType("MACFUSE"))
        #expect(MountManager.isFuseFileSystemType("fuse-t"))
        // The FSKit module registers a "macFUSE (FSKit)" personality; its
        // exact statfs name hasn't been observed here, hence the loose match.
        #expect(MountManager.isFuseFileSystemType("macFUSE (FSKit)"))
        #expect(!MountManager.isFuseFileSystemType("ntfs"))
        #expect(!MountManager.isFuseFileSystemType("apfs"))
        #expect(!MountManager.isFuseFileSystemType("exfat"))
    }
}
