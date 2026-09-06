import Testing
@testable import AppNTFSKit

@Suite("HelperRequestValidation")
struct HelperRequestValidationTests {
    @Test("Accepts the ntfs-3g-mac binaries under a known Homebrew prefix")
    func acceptsKnownExecutables() {
        #expect(HelperRequestValidation.isValidExecutablePath("/opt/homebrew/opt/ntfs-3g-mac/bin/ntfs-3g"))
        #expect(HelperRequestValidation.isValidExecutablePath("/opt/homebrew/opt/ntfs-3g-mac/bin/ntfs-3g.probe"))
        #expect(HelperRequestValidation.isValidExecutablePath("/usr/local/opt/ntfs-3g-mac/bin/ntfsfix"))
    }

    @Test("Rejects arbitrary executables, other prefixes, and path traversal")
    func rejectsUnexpectedExecutables() {
        #expect(!HelperRequestValidation.isValidExecutablePath("/bin/sh"))
        #expect(!HelperRequestValidation.isValidExecutablePath("/tmp/evil/ntfs-3g"))
        #expect(!HelperRequestValidation.isValidExecutablePath("/opt/homebrew/opt/ntfs-3g-mac/bin/../../../../bin/sh"))
        #expect(!HelperRequestValidation.isValidExecutablePath("/opt/homebrew/opt/ntfs-3g-mac/bin/rm"))
        #expect(!HelperRequestValidation.isValidExecutablePath("relative/ntfs-3g"))
    }

    @Test("Accepts disk device nodes, rejects anything else")
    func devicePaths() {
        #expect(HelperRequestValidation.isValidDevicePath("/dev/disk4s1"))
        #expect(HelperRequestValidation.isValidDevicePath("/dev/rdisk4s1"))
        #expect(HelperRequestValidation.isValidDevicePath("/dev/disk4"))
        #expect(!HelperRequestValidation.isValidDevicePath("/dev/rdisk4s1; rm -rf /"))
        #expect(!HelperRequestValidation.isValidDevicePath("/etc/passwd"))
        #expect(!HelperRequestValidation.isValidDevicePath("/dev/../etc/passwd"))
    }

    @Test("Mount path must be a single leaf directly under /Volumes")
    func mountPaths() {
        #expect(HelperRequestValidation.isValidMountPath("/Volumes/MyDrive"))
        #expect(HelperRequestValidation.isValidMountPath("/Volumes/Disco de Juan"))
        #expect(!HelperRequestValidation.isValidMountPath("/Volumes/a/b"))
        #expect(!HelperRequestValidation.isValidMountPath("/Volumes/../etc"))
        #expect(!HelperRequestValidation.isValidMountPath("/Volumes/"))
        #expect(!HelperRequestValidation.isValidMountPath("/tmp/MyDrive"))
    }

    @Test("Mount options are limited to the known key set")
    func mountOptions() {
        #expect(HelperRequestValidation.isValidMountOptions("volname=MyDrive,windows_names,auto_xattr,local_lockfile"))
        #expect(HelperRequestValidation.isValidMountOptions("windows_names,auto_xattr,local_lockfile"))
        #expect(!HelperRequestValidation.isValidMountOptions("volname=x,allow_other"))
        #expect(!HelperRequestValidation.isValidMountOptions("rw,uid=0"))
        #expect(!HelperRequestValidation.isValidMountOptions(""))
    }

    @Test("The options Ntfs3gCommand produces pass validation")
    func producedOptionsAreValid() {
        let command = Ntfs3gCommand(runner: FakeProcessRunner(), homebrewPrefix: "/opt/homebrew")
        #expect(HelperRequestValidation.isValidMountOptions(command.mountOptions(volumeName: "MyDrive")))
        #expect(HelperRequestValidation.isValidMountOptions(command.mountOptions(volumeName: "weird,name\nhere")))
        #expect(HelperRequestValidation.isValidExecutablePath(command.executablePath))
        #expect(HelperRequestValidation.isValidExecutablePath(command.probeExecutablePath))
        #expect(HelperRequestValidation.isValidExecutablePath(command.fixExecutablePath))
    }
}
