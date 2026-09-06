import Testing
import Foundation
@testable import AppNTFSKit

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test("Runs a quick command and captures its output")
    func capturesOutput() async throws {
        let result = try await ProcessRunner().run(
            executable: "/bin/echo",
            arguments: ["hola"]
        )
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == "hola\n")
    }

    @Test("Non-zero exit is reported, not thrown")
    func nonZeroExit() async throws {
        let result = try await ProcessRunner().run(executable: "/usr/bin/false", arguments: [])
        #expect(result.exitCode != 0)
        #expect(!result.succeeded)
    }

    @Test("A hung process is terminated and surfaces as .timedOut")
    func timesOut() async {
        let start = ContinuousClock.now
        do {
            _ = try await ProcessRunner().run(
                executable: "/bin/sleep",
                arguments: ["30"],
                timeout: .milliseconds(300)
            )
            Issue.record("Expected a timeout")
        } catch let ProcessRunnerError.timedOut(executable, _) {
            #expect(executable == "/bin/sleep")
        } catch {
            Issue.record("Expected ProcessRunnerError.timedOut, got \(error)")
        }
        #expect(start.duration(to: .now) < .seconds(5))
    }
}
