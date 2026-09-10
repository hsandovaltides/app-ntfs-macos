import Testing
@testable import AppNTFSKit

@Suite("DependencyChecker")
struct DependencyCheckerTests {
    @Test("Nothing installed")
    func nothingInstalled() async {
        let checker = DependencyChecker(
            runner: FakeProcessRunner(),
            fileSystem: FakeFileSystemProbe(),
            helperStatusProbe: FakeHelperServiceStatusProbe(state: .notInstalled)
        )
        let status = await checker.checkAll()

        #expect(status.homebrewPrefix == nil)
        #expect(status.ntfs3gInstalled == false)
        #expect(status.macFUSEState == .notInstalled)
        #expect(status.helperState == .notInstalled)
        #expect(status.isReady == false)
    }

    @Test("Homebrew and ntfs-3g-mac installed, macFUSE cask installed but not yet approved")
    func pendingApproval() async {
        let fileSystem = FakeFileSystemProbe(
            existingPaths: ["/opt/homebrew/Caskroom/macfuse"],
            executablePaths: [
                "/opt/homebrew/bin/brew",
                "/opt/homebrew/opt/ntfs-3g-mac/bin/ntfs-3g"
            ]
        )
        let runner = FakeProcessRunner(responses: [
            "/usr/bin/systemextensionsctl": ProcessResult(
                exitCode: 0,
                standardOutput: SampleSystemExtensionsOutput.macFUSEPendingApproval,
                standardError: ""
            )
        ])

        let status = await DependencyChecker(
            runner: runner,
            fileSystem: fileSystem,
            helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedAndApproved)
        ).checkAll()

        #expect(status.homebrewPrefix == "/opt/homebrew")
        #expect(status.ntfs3gInstalled == true)
        #expect(status.macFUSEState == .installedPendingApproval)
        #expect(status.isReady == false)
    }

    @Test("Everything installed and approved")
    func fullyReady() async {
        let fileSystem = FakeFileSystemProbe(
            existingPaths: ["/opt/homebrew/Caskroom/macfuse"],
            executablePaths: [
                "/opt/homebrew/bin/brew",
                "/opt/homebrew/opt/ntfs-3g-mac/bin/ntfs-3g"
            ]
        )
        let runner = FakeProcessRunner(responses: [
            "/usr/bin/systemextensionsctl": ProcessResult(
                exitCode: 0,
                standardOutput: SampleSystemExtensionsOutput.macFUSEApproved,
                standardError: ""
            )
        ])

        let status = await DependencyChecker(
            runner: runner,
            fileSystem: fileSystem,
            helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedAndApproved)
        ).checkAll()

        #expect(status.macFUSEState == .installedAndApproved)
        #expect(status.helperState == .installedAndApproved)
        #expect(status.isReady == true)
    }

    @Test("Missing Full Disk Access blocks readiness even when everything else is approved")
    func missingFullDiskAccessBlocksReadiness() async {
        let fileSystem = FakeFileSystemProbe(
            existingPaths: ["/opt/homebrew/Caskroom/macfuse"],
            executablePaths: [
                "/opt/homebrew/bin/brew",
                "/opt/homebrew/opt/ntfs-3g-mac/bin/ntfs-3g"
            ]
        )
        let runner = FakeProcessRunner(responses: [
            "/usr/bin/systemextensionsctl": ProcessResult(
                exitCode: 0,
                standardOutput: SampleSystemExtensionsOutput.macFUSEApproved,
                standardError: ""
            )
        ])

        let status = await DependencyChecker(
            runner: runner,
            fileSystem: fileSystem,
            helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedAndApproved),
            fullDiskAccessProbe: FakeFullDiskAccessProbe(granted: false)
        ).checkAll()

        #expect(status.fullDiskAccessGranted == false)
        #expect(status.isReady == false)
    }

    @Test("Full Disk Access isn't probed (nor blocks readiness) until the helper is approved")
    func fullDiskAccessNotProbedBeforeHelperApproval() async {
        let status = await DependencyChecker(
            runner: FakeProcessRunner(),
            fileSystem: FakeFileSystemProbe(),
            helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedPendingApproval),
            fullDiskAccessProbe: FakeFullDiskAccessProbe(granted: false)
        ).checkAll()

        // Probe would say `false`, but with the helper still pending approval
        // that failure is meaningless — it must not surface as "FDA missing".
        #expect(status.fullDiskAccessGranted == true)
    }

    @Test("Falls back from /opt/homebrew to /usr/local when only Intel prefix has brew")
    func intelPrefixFallback() async {
        let fileSystem = FakeFileSystemProbe(executablePaths: ["/usr/local/bin/brew"])
        let status = await DependencyChecker(
            runner: FakeProcessRunner(),
            fileSystem: fileSystem,
            helperStatusProbe: FakeHelperServiceStatusProbe(state: .notInstalled)
        ).checkAll()

        #expect(status.homebrewPrefix == "/usr/local")
    }

    @Test("Embedded binaries are preferred over a Homebrew install")
    func prefersBundledBinaries() async {
        let helpers = "/Applications/AppNTFS.app/Contents/Helpers"
        let fileSystem = FakeFileSystemProbe(
            existingPaths: ["/Library/Filesystems/macfuse.fs"],
            executablePaths: [
                "/opt/homebrew/bin/brew",
                "/opt/homebrew/opt/ntfs-3g-mac/bin/ntfs-3g",
                "\(helpers)/ntfs-3g",
                "\(helpers)/ntfs-3g.probe",
                "\(helpers)/ntfsfix"
            ]
        )
        let status = await DependencyChecker(
            runner: FakeProcessRunner(),
            fileSystem: fileSystem,
            helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedAndApproved),
            bundledBinariesDirectory: helpers
        ).checkAll()

        #expect(status.ntfs3gBinDirectory == helpers)
        #expect(status.homebrewPrefix == "/opt/homebrew")
    }

    @Test("A partial embed falls back to Homebrew instead of half-using the bundle")
    func partialBundleFallsBackToHomebrew() async {
        let helpers = "/Applications/AppNTFS.app/Contents/Helpers"
        let fileSystem = FakeFileSystemProbe(
            existingPaths: ["/Library/Filesystems/macfuse.fs"],
            executablePaths: [
                "/opt/homebrew/bin/brew",
                "/opt/homebrew/opt/ntfs-3g-mac/bin/ntfs-3g",
                // ntfsfix and ntfs-3g.probe missing: a broken embed step.
                "\(helpers)/ntfs-3g"
            ]
        )
        let status = await DependencyChecker(
            runner: FakeProcessRunner(),
            fileSystem: fileSystem,
            helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedAndApproved),
            bundledBinariesDirectory: helpers
        ).checkAll()

        #expect(status.ntfs3gBinDirectory == "/opt/homebrew/opt/ntfs-3g-mac/bin")
    }

    @Test("Ready with the embedded binaries and no Homebrew at all")
    func readyWithoutHomebrew() async {
        let helpers = "/Applications/AppNTFS.app/Contents/Helpers"
        let fileSystem = FakeFileSystemProbe(
            existingPaths: ["/Library/Filesystems/macfuse.fs"],
            executablePaths: [
                "\(helpers)/ntfs-3g",
                "\(helpers)/ntfs-3g.probe",
                "\(helpers)/ntfsfix"
            ]
        )
        let runner = FakeProcessRunner(responses: [
            "/usr/bin/systemextensionsctl": ProcessResult(
                exitCode: 0,
                standardOutput: SampleSystemExtensionsOutput.macFUSEApproved,
                standardError: ""
            )
        ])
        let status = await DependencyChecker(
            runner: runner,
            fileSystem: fileSystem,
            helperStatusProbe: FakeHelperServiceStatusProbe(state: .installedAndApproved),
            bundledBinariesDirectory: helpers
        ).checkAll()

        // Homebrew is a delivery mechanism, not a dependency: with ntfs-3g
        // shipped inside the app, its absence must not block readiness.
        #expect(status.homebrewPrefix == nil)
        #expect(status.ntfs3gInstalled)
        #expect(status.isReady)
    }
}
