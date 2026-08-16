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
}
