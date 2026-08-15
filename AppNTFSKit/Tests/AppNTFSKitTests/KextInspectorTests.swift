import Testing
@testable import AppNTFSKit

@Suite("KextInspector")
struct KextInspectorTests {
    @Test("Detects the macFUSE kext when loaded")
    func loaded() {
        let output = """
        Index Refs Address            Size       Wired      Name (Version) UUID <Linked Against>
          257    0 0                  0x1830     0x1830     io.macfuse.filesystems.macfuse.25 (5.3.3) 46DF9FD0-17F3-31EF-AC17-0D5EE976A453 <9 7 6 5 3>
        """
        #expect(KextInspector.macFUSEIsLoaded(fromOutput: output))
    }

    @Test("Reports not loaded when the kext isn't in the list")
    func notLoaded() {
        let output = """
        Index Refs Address            Size       Wired      Name (Version) UUID <Linked Against>
            3  212 0                  0          0          com.apple.kpi.bsd (25.6.0) B895CFBD-5729-3AD8-8622-F69131E7A451 <>
        """
        #expect(!KextInspector.macFUSEIsLoaded(fromOutput: output))
    }
}
