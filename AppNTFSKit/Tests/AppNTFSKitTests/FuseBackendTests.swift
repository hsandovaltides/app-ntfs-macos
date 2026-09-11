import Foundation
import Testing
@testable import AppNTFSKit

@Suite("FuseBackend")
struct FuseBackendTests {
    private func command() -> Ntfs3gCommand {
        Ntfs3gCommand(runner: FakeProcessRunner(), homebrewPrefix: "/opt/homebrew")
    }

    @Test("The FSKit backend is named in the mount options; the kext isn't")
    func mountOptionToken() {
        // `backend=fskit` is what makes libfuse route the mount through
        // macFUSE's file-system extension instead of the kext. There is no
        // equivalent token for the kext: it is what libfuse does when no
        // backend is named, and naming it explicitly would only widen what
        // the helper has to accept.
        #expect(FuseBackend.fskit.mountOptionToken == "backend=fskit")
        #expect(FuseBackend.kext.mountOptionToken == nil)
    }

    @Test("backend= is prepended without disturbing the existing options")
    func optionsWithBackend() {
        #expect(command().mountOptions(volumeName: "MyDrive", backend: .fskit)
            == "backend=fskit,volname=MyDrive,windows_names,auto_xattr,local_lockfile")
        #expect(command().mountOptions(volumeName: "MyDrive", backend: .kext)
            == "volname=MyDrive,windows_names,auto_xattr,local_lockfile")
    }

    @Test("The default backend is still the kext")
    func kextIsTheDefault() {
        // Callers that predate the FSKit work — and the helper's own
        // validation fixtures — must keep meaning exactly what they meant.
        #expect(command().mountOptions(volumeName: "MyDrive")
            == command().mountOptions(volumeName: "MyDrive", backend: .kext))
    }

    @Test("Volume names are sanitized the same way with a backend in play")
    func sanitizingIsUnaffected() {
        #expect(command().mountOptions(volumeName: "Disco,rw", backend: .fskit)
            == "backend=fskit,volname=Discorw,windows_names,auto_xattr,local_lockfile")
        #expect(command().mountOptions(volumeName: ",,\n", backend: .fskit)
            == "backend=fskit,windows_names,auto_xattr,local_lockfile")
    }
}

@Suite("FuseBackendAvailability")
struct FuseBackendAvailabilityTests {
    private static let extensionPath =
        "\(FuseBackendAvailability.macFUSEExtensionsDirectory)/\(FuseBackendAvailability.macFUSEFSKitExtensionName)"

    @Test("Plausible when the OS is new enough and macFUSE ships its extension")
    func plausible() {
        #expect(FuseBackendAvailability.fskitIsPlausible(
            fileSystem: FakeFileSystemProbe(existingPaths: [Self.extensionPath]),
            operatingSystemIsAtLeast: { _ in true }
        ))
    }

    @Test("Not plausible before macOS 15.4, extension or not")
    func tooOld() {
        // FSKit's file-system-extension entry point doesn't exist before
        // 15.4, so an older machine has to keep using the kext even with a
        // current macFUSE installed.
        #expect(!FuseBackendAvailability.fskitIsPlausible(
            fileSystem: FakeFileSystemProbe(existingPaths: [Self.extensionPath]),
            operatingSystemIsAtLeast: { _ in false }
        ))
    }

    @Test("Not plausible when macFUSE predates the FSKit module")
    func extensionMissing() {
        #expect(!FuseBackendAvailability.fskitIsPlausible(
            fileSystem: FakeFileSystemProbe(),
            operatingSystemIsAtLeast: { _ in true }
        ))
    }
}
