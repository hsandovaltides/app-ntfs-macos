import Testing
@testable import AppNTFSKit

@Suite("BundledNtfs3g")
struct BundledNtfs3gTests {
    @Test("Derives Contents/Helpers from an executable inside an app bundle")
    func derivesHelpersDirectory() {
        #expect(
            BundledNtfs3g.directory(forHostExecutable: "/Applications/AppNTFS.app/Contents/MacOS/AppNTFS")
                == "/Applications/AppNTFS.app/Contents/Helpers"
        )
    }

    @Test("Returns nil for an executable that is not inside an app bundle")
    func rejectsNonBundledExecutable() {
        // The whole point of deriving the directory from the running
        // executable is that it cannot be spoofed. Anything that isn't
        // laid out as `…/Contents/MacOS/<binary>` gets no bundled directory
        // at all, so the helper falls back to the Homebrew allow-list rather
        // than trusting a directory next to some arbitrary binary.
        #expect(BundledNtfs3g.directory(forHostExecutable: "/usr/local/bin/appntfs") == nil)
        #expect(BundledNtfs3g.directory(forHostExecutable: "/tmp/Contents/Helpers/ntfs-3g") == nil)
        #expect(BundledNtfs3g.directory(forHostExecutable: "/tmp/evil/MacOS/AppNTFS") == nil)
    }
}

@Suite("Ntfs3gCommand paths")
struct Ntfs3gCommandPathTests {
    @Test("Resolves the three binaries inside a bundled Helpers directory")
    func resolvesBundledPaths() {
        let command = Ntfs3gCommand(
            runner: FakeProcessRunner(),
            binDirectory: "/Applications/AppNTFS.app/Contents/Helpers"
        )
        #expect(command.executablePath == "/Applications/AppNTFS.app/Contents/Helpers/ntfs-3g")
        #expect(command.probeExecutablePath == "/Applications/AppNTFS.app/Contents/Helpers/ntfs-3g.probe")
        #expect(command.fixExecutablePath == "/Applications/AppNTFS.app/Contents/Helpers/ntfsfix")
    }

    @Test("The Homebrew initialiser still resolves the opt/ symlink layout")
    func resolvesHomebrewPaths() {
        let command = Ntfs3gCommand(runner: FakeProcessRunner(), homebrewPrefix: "/opt/homebrew")
        #expect(command.executablePath == "/opt/homebrew/opt/ntfs-3g-mac/bin/ntfs-3g")
    }
}
