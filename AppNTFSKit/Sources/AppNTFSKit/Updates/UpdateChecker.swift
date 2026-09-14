import Foundation

public struct ReleaseInfo: Sendable, Equatable {
    /// Without the leading `v` — comparable to `CFBundleShortVersionString`.
    public let version: String
    /// The release's human-readable page, not the asset: the download is a
    /// zip that needs its quarantine flag cleared, and the page is where the
    /// notes explaining that live.
    public let pageURL: URL

    public init(version: String, pageURL: URL) {
        self.version = version
        self.pageURL = pageURL
    }
}

public enum UpdateCheckError: Error, CustomStringConvertible, Equatable {
    case network(String)
    case malformedResponse

    public var description: String {
        switch self {
        case .network(let detail): return "No se pudo consultar las actualizaciones: \(detail)"
        case .malformedResponse: return "La respuesta de GitHub no se pudo interpretar"
        }
    }
}

/// Seam so `UpdateChecker` can be tested without reaching the network.
public protocol ReleaseFeedFetching: Sendable {
    func latestRelease() async throws -> ReleaseInfo
}

/// Reads `releases/latest` from GitHub's public API. Unauthenticated on
/// purpose — this is a public repository and the endpoint needs no token, so
/// the app never has to hold a credential to answer "is there a newer build?".
public struct GitHubReleaseFeed: ReleaseFeedFetching {
    /// `owner/repo`. Matches the URL the Homebrew cask installs from.
    public static let repository = "hsandovaltides/app-ntfs-macos"

    private let session: URLSession
    private let repository: String

    public init(repository: String = GitHubReleaseFeed.repository, session: URLSession = .shared) {
        self.repository = repository
        self.session = session
    }

    private struct Payload: Decodable {
        let tagName: String
        let htmlURL: String
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
        }
    }

    public func latestRelease() async throws -> ReleaseInfo {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateCheckError.malformedResponse
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // A check that hangs must not outlive the user's patience with a menu
        // item they clicked; this is strictly a nicety, never a blocker.
        request.timeoutInterval = 15

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw UpdateCheckError.network("\(error)")
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.draft, !payload.prerelease,
              let pageURL = URL(string: payload.htmlURL) else {
            throw UpdateCheckError.malformedResponse
        }
        let version = payload.tagName.hasPrefix("v")
            ? String(payload.tagName.dropFirst())
            : payload.tagName
        return ReleaseInfo(version: version, pageURL: pageURL)
    }
}

/// Answers "is there a newer release than the one running?".
///
/// The app is distributed as a zip from GitHub Releases and a Homebrew cask,
/// neither of which tells a running copy that it has fallen behind — and the
/// release workflow publishes a new patch version on every merge to `main`, so
/// an install goes stale quickly and silently.
public struct UpdateChecker: Sendable {
    private let feed: ReleaseFeedFetching

    public init(feed: ReleaseFeedFetching = GitHubReleaseFeed()) {
        self.feed = feed
    }

    /// The newer release, or `nil` when this build is current.
    public func availableUpdate(currentVersion: String) async throws -> ReleaseInfo? {
        let latest = try await feed.latestRelease()
        return Self.isNewer(latest.version, than: currentVersion) ? latest : nil
    }

    /// Numeric, component-wise comparison — `"0.1.10"` is newer than `"0.1.9"`,
    /// which a plain string comparison gets backwards. Missing components count
    /// as zero, so `"0.2"` and `"0.2.0"` are the same version. Anything
    /// non-numeric compares as zero rather than throwing: a hand-built local
    /// copy shouldn't be nagged about an update it may well be ahead of.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = components(of: candidate)
        let right = components(of: current)
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private static func components(of version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}
