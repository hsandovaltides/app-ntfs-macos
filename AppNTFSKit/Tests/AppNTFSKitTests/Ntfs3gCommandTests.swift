import Testing
@testable import AppNTFSKit

@Suite("Ntfs3gCommand")
struct Ntfs3gCommandTests {
    private func command() -> Ntfs3gCommand {
        Ntfs3gCommand(runner: FakeProcessRunner(), homebrewPrefix: "/opt/homebrew")
    }

    @Test("A normal volume name is passed through as volname=")
    func normalVolumeName() {
        #expect(command().mountOptions(volumeName: "MyDrive")
            == "volname=MyDrive,windows_names,auto_xattr,local_lockfile")
    }

    @Test("Commas and control characters are stripped so they can't inject mount options")
    func sanitizesSeparators() {
        let options = command().mountOptions(volumeName: "Disco,rw\nallow_other")
        #expect(options == "volname=Discorwallow_other,windows_names,auto_xattr,local_lockfile")
    }

    @Test("A name that sanitizes to empty drops the volname option entirely")
    func emptyAfterSanitizing() {
        #expect(command().mountOptions(volumeName: ",,\n")
            == "windows_names,auto_xattr,local_lockfile")
    }

    @Test("Unicode volume names (accents, emoji) are preserved")
    func keepsUnicode() {
        #expect(command().mountOptions(volumeName: "Cañón 🎉")
            == "volname=Cañón 🎉,windows_names,auto_xattr,local_lockfile")
    }
}
