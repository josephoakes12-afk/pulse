import Foundation

/// A marketing version with an optional, explicit Mac build suffix. An ordinary
/// release tag has no build information and never implies a newer rebuild.
public struct PulseAppVersion: Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let build: Int?
    public var marketingVersion: String { "\(major).\(minor).\(patch)" }

    public init?(version: String, build: String? = nil) {
        let value = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = value.split(separator: "+", omittingEmptySubsequences: false)
        guard parts.count <= 2, let components = Self.numbers(String(parts[0]), count: 3) else { return nil }
        let rawBuild = parts.count == 2 ? String(parts[1]) : build
        let buildNumber: Int?
        if let rawBuild {
            guard let number = Self.numbers(rawBuild, count: 1)?.first else { return nil }
            buildNumber = number
        } else { buildNumber = nil }
        major = components[0]; minor = components[1]; patch = components[2]; self.build = buildNumber
    }

    public func isNewer(than other: PulseAppVersion) -> Bool {
        let current = [major, minor, patch], previous = [other.major, other.minor, other.patch]
        if current != previous { return previous.lexicographicallyPrecedes(current) }
        guard let build, let installedBuild = other.build else { return false }
        return build > installedBuild
    }

    private static func numbers(_ value: String, count: Int) -> [Int]? {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == count else { return nil }
        var result: [Int] = []
        for piece in pieces {
            guard (1...9).contains(piece.utf8.count), piece.utf8.allSatisfy({ (48...57).contains($0) }),
                  piece == "0" || !piece.hasPrefix("0"), let number = Int(piece) else { return nil }
            result.append(number)
        }
        return result
    }
}

public struct PulseRelease: Equatable, Sendable {
    public let version: PulseAppVersion
    public let releaseURL: URL
}

public enum PulseUpdateResult: Equatable, Sendable {
    case upToDate
    case available(PulseRelease)
    case unreleased
}

public enum PulseUpdateError: LocalizedError, Equatable, Sendable {
    case unavailable
    case invalidRelease
    public var errorDescription: String? { "Couldn’t check for updates. Try again later." }
}

/// A manual, unauthenticated check against Pulse's public release. This neither
/// downloads nor runs an installer and does not share any project information.
public struct PulseReleaseClient: Sendable {
    public static let endpoint = URL(string: "https://api.github.com/repos/josephoakes12-afk/pulse/releases/latest")!
    public static let maximumResponseBytes = 1_048_576
    private static let repositoryPath = "/josephoakes12-afk/pulse"
    private let transport: HTTPConnector.Transport

    public init() { transport = { request in try await HTTPConnector.fetch(request) } }
    public init(transport: @escaping HTTPConnector.Transport) { self.transport = transport }

    public func check(installed: PulseAppVersion) async throws -> PulseUpdateResult {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Pulse-update-check", forHTTPHeaderField: "User-Agent")
        let response: HTTPURLResponse
        let data: Data
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw PulseUpdateError.unavailable }
        guard response.url == Self.endpoint, data.count <= Self.maximumResponseBytes else { throw PulseUpdateError.invalidRelease }
        if response.statusCode == 404 { return .unreleased }
        guard response.statusCode == 200 else { throw PulseUpdateError.unavailable }
        return try Self.result(data: data, installed: installed)
    }

    public static func result(data: Data, installed: PulseAppVersion) throws -> PulseUpdateResult {
        guard data.count <= maximumResponseBytes,
              let release = try? JSONDecoder().decode(ReleaseResponse.self, from: data),
              !release.draft, !release.prerelease,
              let version = PulseAppVersion(version: release.tagName),
              let releaseURL = trustedURL(release.htmlURL, path: repositoryPath + "/releases/tag/" + release.tagName),
              release.assets.count <= 20 else { throw PulseUpdateError.invalidRelease }
        let fileName = "Pulse-\(version.marketingVersion)-macOS.dmg"
        let assetPath = repositoryPath + "/releases/download/" + release.tagName + "/" + fileName
        guard release.assets.contains(where: {
            $0.name == fileName && $0.state == "uploaded" && (1...100_000_000).contains($0.size) &&
            trustedURL($0.downloadURL, path: assetPath) != nil
        }) else { return .unreleased }
        return version.isNewer(than: installed) ? .available(PulseRelease(version: version, releaseURL: releaseURL)) : .upToDate
    }

    private static func trustedURL(_ value: String, path: String) -> URL? {
        guard let parts = URLComponents(string: value), parts.scheme == "https", parts.host == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.removingPercentEncoding == path else { return nil }
        // Build the action URL from the known repository and validated tag.
        return URL(string: "https://github.com" + path)
    }

    private struct ReleaseResponse: Decodable {
        let tagName: String
        let htmlURL: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", htmlURL = "html_url", draft, prerelease, assets }
    }
    private struct Asset: Decodable {
        let name: String
        let state: String
        let size: Int
        let downloadURL: String
        enum CodingKeys: String, CodingKey { case name, state, size, downloadURL = "browser_download_url" }
    }
}
