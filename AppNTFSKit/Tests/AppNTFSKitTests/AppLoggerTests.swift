import Testing
@testable import AppNTFSKit

@Suite("AppLogger")
struct AppLoggerTests {
    @Test("clear() empties the in-memory buffer")
    func clearEmptiesBuffer() {
        let logger = AppLogger()
        logger.info("one")
        logger.warning("two")
        #expect(logger.entries.count == 2)

        logger.clear()

        #expect(logger.entries.isEmpty)
    }
}
