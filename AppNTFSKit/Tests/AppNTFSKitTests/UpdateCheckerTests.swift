import Foundation
import Testing
@testable import AppNTFSKit

private struct FakeReleaseFeed: ReleaseFeedFetching {
    let release: ReleaseInfo?

    func latestRelease() async throws -> ReleaseInfo {
        guard let release else { throw UpdateCheckError.malformedResponse }
        return release
    }
}

private func release(_ version: String) -> ReleaseInfo {
    ReleaseInfo(version: version, pageURL: URL(string: "https://example.com/\(version)")!)
}

@Suite("UpdateChecker")
struct UpdateCheckerTests {
    /// The regression a string comparison would produce: "0.1.10" < "0.1.9"
    /// lexicographically, so an install would sit on .9 forever exactly when
    /// the patch counter rolls past a single digit — which this project's
    /// per-merge release workflow reaches quickly.
    @Test func comparesVersionComponentsNumerically() {
        #expect(UpdateChecker.isNewer("0.1.10", than: "0.1.9"))
        #expect(!UpdateChecker.isNewer("0.1.9", than: "0.1.10"))
        #expect(UpdateChecker.isNewer("0.2.0", than: "0.1.99"))
        #expect(UpdateChecker.isNewer("1.0.0", than: "0.99.99"))
    }

    @Test func treatsMissingComponentsAsZero() {
        #expect(!UpdateChecker.isNewer("0.2", than: "0.2.0"))
        #expect(!UpdateChecker.isNewer("0.2.0", than: "0.2"))
        #expect(UpdateChecker.isNewer("0.2.1", than: "0.2"))
    }

    @Test func identicalVersionIsNotNewer() {
        #expect(!UpdateChecker.isNewer("0.1.7", than: "0.1.7"))
    }

    @Test func nonNumericComponentsDoNotTriggerAnUpdate() {
        #expect(!UpdateChecker.isNewer("dev", than: "0.1.7"))
    }

    @Test func reportsANewerRelease() async throws {
        let checker = UpdateChecker(feed: FakeReleaseFeed(release: release("0.1.8")))
        let update = try await checker.availableUpdate(currentVersion: "0.1.7")
        #expect(update?.version == "0.1.8")
    }

    @Test func reportsNothingWhenCurrent() async throws {
        let checker = UpdateChecker(feed: FakeReleaseFeed(release: release("0.1.7")))
        #expect(try await checker.availableUpdate(currentVersion: "0.1.7") == nil)
    }

    /// A locally built copy can legitimately be ahead of the newest release;
    /// offering it a "downgrade" would be worse than saying nothing.
    @Test func reportsNothingWhenAheadOfTheLatestRelease() async throws {
        let checker = UpdateChecker(feed: FakeReleaseFeed(release: release("0.1.7")))
        #expect(try await checker.availableUpdate(currentVersion: "0.2.0") == nil)
    }

    @Test func propagatesFeedFailures() async {
        let checker = UpdateChecker(feed: FakeReleaseFeed(release: nil))
        await #expect(throws: UpdateCheckError.malformedResponse) {
            _ = try await checker.availableUpdate(currentVersion: "0.1.7")
        }
    }
}
