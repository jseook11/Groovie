import Foundation
import os

/// Watches the public GitHub release feed and reports newer versions.
///
/// Groovie ships as an ad-hoc signed zip, so Sparkle-style in-place updates are
/// not possible yet. This checker only reads release metadata; it never
/// downloads or installs anything. The UI is expected to open the release page.
final class UpdateChecker {
    struct Release: Equatable, Sendable {
        let version: String
        let pageURL: URL
    }

    enum Outcome: Equatable, Sendable {
        case upToDate(current: String)
        case available(current: String, release: Release)
        case failed
    }

    private enum Keys {
        static let lastCheck = "groovie.update.lastCheck"
        static let availableVersion = "groovie.update.availableVersion"
        static let availablePage = "groovie.update.availablePage"
    }

    static let releasesAPI = URL(string: "https://api.github.com/repos/jseook11/Groovie/releases/latest")!
    static let checkInterval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let session: URLSession
    private let log = Logger(subsystem: "com.groovie.app", category: "update")

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
    }

    /// Version baked into the app bundle, or nil when the executable runs
    /// outside an `.app` (for example `swift run`).
    static func bundledVersion(bundle: Bundle = .main) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Automatic checks run at most once a day. A failed request does not
    /// advance the timestamp, so the next launch retries.
    func shouldCheckAutomatically(now: Date = Date()) -> Bool {
        guard let last = defaults.object(forKey: Keys.lastCheck) as? Date else { return true }
        return now.timeIntervalSince(last) >= Self.checkInterval
    }

    /// The release found on a previous launch, while it is still newer than the
    /// running version. Keeps the menu entry visible without re-fetching.
    func cachedUpdate(currentVersion: String) -> Release? {
        guard let version = defaults.string(forKey: Keys.availableVersion),
              let rawURL = defaults.string(forKey: Keys.availablePage),
              let url = URL(string: rawURL),
              Self.isNewer(version, than: currentVersion)
        else { return nil }
        return Release(version: version, pageURL: url)
    }

    func check(currentVersion: String, force: Bool = false) async -> Outcome {
        if !force, !shouldCheckAutomatically() {
            return cachedUpdate(currentVersion: currentVersion)
                .map { .available(current: currentVersion, release: $0) } ?? .upToDate(current: currentVersion)
        }

        var request = URLRequest(
            url: Self.releasesAPI,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Groovie/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            guard (200..<300).contains(http.statusCode) else {
                log.info("Release check returned HTTP \(http.statusCode, privacy: .public)")
                return .failed
            }

            defaults.set(Date(), forKey: Keys.lastCheck)
            guard let release = Self.release(from: data, currentVersion: currentVersion) else {
                clearCachedUpdate()
                return .upToDate(current: currentVersion)
            }
            store(release)
            return .available(current: currentVersion, release: release)
        } catch {
            log.debug("Release check failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    /// Decodes a `/releases/latest` payload and returns it only when its tag is
    /// newer than the running version.
    static func release(from data: Data, currentVersion: String) -> Release? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let tag = payload.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isNewer(tag, than: currentVersion) else { return nil }

        let page = payload.htmlURL.flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/jseook11/Groovie/releases/tag/\(tag)")
        guard let page else { return nil }

        return Release(version: displayVersion(tag), pageURL: page)
    }

    /// Compares dotted versions. A leading `v` and build metadata are ignored;
    /// an unparseable value never counts as newer, so a bad tag cannot nag.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidate = Version(candidate), let current = Version(current) else {
            return false
        }
        return candidate > current
    }

    static func displayVersion(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        return value
    }

    // MARK: - Persistence

    private func store(_ release: Release) {
        defaults.set(release.version, forKey: Keys.availableVersion)
        defaults.set(release.pageURL.absoluteString, forKey: Keys.availablePage)
    }

    private func clearCachedUpdate() {
        defaults.removeObject(forKey: Keys.availableVersion)
        defaults.removeObject(forKey: Keys.availablePage)
    }

    // MARK: - Decoding

    private struct Payload: Decodable {
        let tagName: String
        let htmlURL: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    /// Minimal SemVer ordering: dotted numeric core plus an optional
    /// prerelease. Missing core components are treated as zero.
    struct Version: Comparable, Equatable {
        let core: [Int]
        let prerelease: [String]?

        init?(_ raw: String) {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
            if let plus = text.firstIndex(of: "+") {
                text = String(text[..<plus])
            }

            var prerelease: [String]?
            if let dash = text.firstIndex(of: "-") {
                let suffix = text[text.index(after: dash)...].split(separator: ".").map(String.init)
                guard !suffix.isEmpty, suffix.allSatisfy({ !$0.isEmpty }) else { return nil }
                prerelease = suffix
                text = String(text[..<dash])
            }

            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty else { return nil }

            var core: [Int] = []
            for part in parts {
                guard !part.isEmpty, let value = Int(part), value >= 0 else { return nil }
                core.append(value)
            }

            self.core = core
            self.prerelease = prerelease
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            let count = max(lhs.core.count, rhs.core.count)
            for index in 0..<count {
                let left = index < lhs.core.count ? lhs.core[index] : 0
                let right = index < rhs.core.count ? rhs.core[index] : 0
                if left != right { return left < right }
            }

            switch (lhs.prerelease, rhs.prerelease) {
            case (nil, nil):
                return false
            case (nil, _):
                return false
            case (_, nil):
                return true
            case let (left?, right?):
                for index in 0..<max(left.count, right.count) {
                    if index >= left.count { return true }
                    if index >= right.count { return false }
                    let a = left[index]
                    let b = right[index]
                    if a == b { continue }
                    let aNumber = Int(a)
                    let bNumber = Int(b)
                    if let aNumber, let bNumber { return aNumber < bNumber }
                    if aNumber != nil { return true }
                    if bNumber != nil { return false }
                    return a < b
                }
                return false
            }
        }
    }
}
