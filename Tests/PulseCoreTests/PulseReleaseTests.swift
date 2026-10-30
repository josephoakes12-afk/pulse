import Foundation
import Testing
@testable import PulseCore

private func releaseData(tag: String = "v0.2.0", draft: Bool = false, prerelease: Bool = false,
                         releaseURL: String? = nil, assetURL: String? = nil,
                         assetState: String = "uploaded", includeAsset: Bool = true) throws -> Data {
    let version = PulseAppVersion(version: tag)?.marketingVersion ?? "0.2.0"
    let name = "Pulse-\(version)-macOS.dmg"
    let asset: [String: Any] = ["name": name, "size": 12_345, "state": assetState,
                              "browser_download_url": assetURL ?? "https://github.com/josephoakes12-afk/pulse/releases/download/\(tag)/\(name)"]
    return try JSONSerialization.data(withJSONObject: [
        "tag_name": tag, "draft": draft, "prerelease": prerelease,
        "html_url": releaseURL ?? "https://github.com/josephoakes12-afk/pulse/releases/tag/\(tag)",
        "assets": includeAsset ? [asset] : []
    ])
}

@Suite struct PulseReleaseTests {
    @Test func numericVersionsAndExplicitBuildsAvoidLexicalOrUnknownBuildUpdates() throws {
        let nine = try #require(PulseAppVersion(version: "0.1.9", build: "4"))
        let ten = try #require(PulseAppVersion(version: "v0.1.10"))
        #expect(ten.isNewer(than: nine))
        #expect(!nine.isNewer(than: ten))
        let current = try #require(PulseAppVersion(version: "0.1.0", build: "5"))
        #expect(try #require(PulseAppVersion(version: "v0.1.0+6")).isNewer(than: current))
        #expect(!((try #require(PulseAppVersion(version: "v0.1.0+4"))).isNewer(than: current)))
        #expect(!((try #require(PulseAppVersion(version: "v0.1.0"))).isNewer(than: current)))
        #expect(!((try #require(PulseAppVersion(version: "v0.1.0+6"))).isNewer(than: try #require(PulseAppVersion(version: "v0.1.0")))))
        for invalid in ["1", "1.2", "1.2.3.4", " 1.2.3", "1.2.3\n", "1.2.3-beta", "1.2.3+beta", "1.02.3", "-1.2.3", "1.2.3+", "1.2.3+1+2", "999999999999.1.0"] {
            #expect(PulseAppVersion(version: invalid) == nil)
        }
    }

    @Test func onlyAStableUploadedMacReleaseBecomesAnUpdate() throws {
        let installed = try #require(PulseAppVersion(version: "0.1.0", build: "5"))
        let result = try PulseReleaseClient.result(data: releaseData(), installed: installed)
        guard case .available(let release) = result else { Issue.record("Expected a stable Mac release"); return }
        #expect(release.version.marketingVersion == "0.2.0")
        #expect(release.releaseURL.absoluteString == "https://github.com/josephoakes12-afk/pulse/releases/tag/v0.2.0")
        #expect(try PulseReleaseClient.result(data: releaseData(tag: "v0.1.0"), installed: installed) == .upToDate)
        #expect(try PulseReleaseClient.result(data: releaseData(tag: "v0.0.9"), installed: installed) == .upToDate)
        #expect(try PulseReleaseClient.result(data: releaseData(tag: "v0.1.0+6"), installed: installed) != .upToDate)
        #expect(try PulseReleaseClient.result(data: releaseData(includeAsset: false), installed: installed) == .unreleased)
        #expect(try PulseReleaseClient.result(data: releaseData(assetState: "new"), installed: installed) == .unreleased)
        #expect(throws: PulseUpdateError.invalidRelease) { try PulseReleaseClient.result(data: releaseData(draft: true), installed: installed) }
        #expect(throws: PulseUpdateError.invalidRelease) { try PulseReleaseClient.result(data: releaseData(prerelease: true), installed: installed) }
        #expect(throws: PulseUpdateError.invalidRelease) { try PulseReleaseClient.result(data: releaseData(tag: "v0.2.0-beta"), installed: installed) }
    }

    @Test func releaseAndAssetURLsCannotEscapeTheFixedRepository() throws {
        let installed = try #require(PulseAppVersion(version: "0.1.0"))
        for url in ["http://github.com/josephoakes12-afk/pulse/releases/tag/v0.2.0",
                    "https://github.com.evil.test/josephoakes12-afk/pulse/releases/tag/v0.2.0",
                    "https://github.com/other/pulse/releases/tag/v0.2.0",
                    "https://user@github.com/josephoakes12-afk/pulse/releases/tag/v0.2.0",
                    "https://github.com:443/josephoakes12-afk/pulse/releases/tag/v0.2.0",
                    "https://github.com/josephoakes12-afk/pulse/releases/tag/v0.2.0?token=secret",
                    "https://github.com/josephoakes12-afk/pulse/releases/tag/v0.2.0#fragment"] {
            #expect(throws: PulseUpdateError.invalidRelease) { try PulseReleaseClient.result(data: releaseData(releaseURL: url), installed: installed) }
        }
        for url in ["https://evil.test/Pulse-0.2.0-macOS.dmg",
                    "https://github.com/other/pulse/releases/download/v0.2.0/Pulse-0.2.0-macOS.dmg",
                    "https://github.com/josephoakes12-afk/pulse/releases/download/v0.1.0/Pulse-0.2.0-macOS.dmg"] {
            #expect(try PulseReleaseClient.result(data: releaseData(assetURL: url), installed: installed) == .unreleased)
        }
    }

    @Test func malformedOrOversizedReleasesAreRejected() throws {
        let installed = try #require(PulseAppVersion(version: "0.1.0"))
        for value in [Data("[]".utf8), Data("{}".utf8), Data("not JSON".utf8), Data(repeating: 32, count: PulseReleaseClient.maximumResponseBytes + 1)] {
            #expect(throws: PulseUpdateError.invalidRelease) { try PulseReleaseClient.result(data: value, installed: installed) }
        }
    }

    @Test func checkUsesOneCredentialFreeFixedRequestAndTreatsMissingPublicReleaseHonestly() async throws {
        let client = PulseReleaseClient(transport: { request in
            #expect(request.url == PulseReleaseClient.endpoint)
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
            return (Data("{}".utf8), HTTPURLResponse(url: PulseReleaseClient.endpoint, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        })
        #expect(try await client.check(installed: #require(PulseAppVersion(version: "0.1.0"))) == .unreleased)
    }

    @Test func redirectedRateLimitedAndCancelledChecksAreNeverReportedAsUpToDate() async throws {
        let installed = try #require(PulseAppVersion(version: "0.1.0"))
        for status in [301, 403, 429, 500] {
            let client = PulseReleaseClient(transport: { _ in
                (Data("{}".utf8), HTTPURLResponse(url: PulseReleaseClient.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
            await #expect(throws: PulseUpdateError.unavailable) { try await client.check(installed: installed) }
        }
        let redirected = PulseReleaseClient(transport: { _ in
            (try releaseData(), HTTPURLResponse(url: URL(string: "https://evil.test/latest")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: PulseUpdateError.invalidRelease) { try await redirected.check(installed: installed) }
        let cancelled = PulseReleaseClient(transport: { _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) { try await cancelled.check(installed: installed) }
    }
}
