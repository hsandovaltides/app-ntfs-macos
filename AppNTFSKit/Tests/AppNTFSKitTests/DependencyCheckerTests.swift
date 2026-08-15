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
}
