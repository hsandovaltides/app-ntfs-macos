import Testing
@testable import AppNTFSKit

@Suite("SystemExtensionInspector")
struct SystemExtensionInspectorTests {
    @Test("Detects an approved macFUSE extension")
    func approved() {
        let state = SystemExtensionInspector.macFUSEApprovalState(fromOutput: SampleSystemExtensionsOutput.macFUSEApproved)
        #expect(state == .approved)
    }

    @Test("Detects macFUSE present but waiting for user approval")
    func pendingApproval() {
        let state = SystemExtensionInspector.macFUSEApprovalState(fromOutput: SampleSystemExtensionsOutput.macFUSEPendingApproval)
        #expect(state == .pendingApproval)
    }

    @Test("Reports not present when macFUSE isn't in the list at all")
    func notPresent() {
        let state = SystemExtensionInspector.macFUSEApprovalState(fromOutput: SampleSystemExtensionsOutput.empty)
        #expect(state == .notPresent)
    }
}
