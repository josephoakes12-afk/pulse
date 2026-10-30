import Foundation
import Testing
@testable import PulseWidgetData

struct CloudSyncSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let publisherID = UUID(uuidString: "A1C8FB2D-E3DA-4CD0-98A6-4D09A23728BF")!

    private func fixture(generatedAt: Date? = nil) -> WidgetSnapshot {
        let timestamp = generatedAt ?? now
        return WidgetSnapshot(generatedAt: timestamp, defaultRangeRawValue: "30d", projects: [
            WidgetProject(id: UUID(), name: "Studio", symbol: "calendar", iconImageData: Data([0, 1, 2]), ranges: [
                WidgetRange(rawValue: "30d", title: "30d", measuredAt: timestamp.addingTimeInterval(-60), metrics: [
                    WidgetMetric(id: UUID(), label: "Accounts", value: "12"),
                    WidgetMetric(id: UUID(), label: "Bookings / account", value: "2.5")
                ])
            ])
        ])
    }

    @Test func syncKeepsOnlyDisplaySummariesAndChoicesAndLeavesLocalIconsIntact() throws {
        let local = fixture()
        let summary = try CloudSyncSnapshot.prepared(publisherID: publisherID, snapshot: local, now: now)
        let data = try summary.encoded(now: now)
        let decoded = try CloudSyncSnapshot.decode(data, now: now)
        #expect(decoded == summary)
        #expect(local.projects[0].iconImageData == Data([0, 1, 2]))
        #expect(decoded.snapshot.projects[0].iconImageData == nil)
        #expect(decoded.snapshot.projects[0].symbol == local.projects[0].symbol)
        #expect(decoded.snapshot.projects[0].id == local.projects[0].id)
        #expect(decoded.snapshot.projects[0].ranges == local.projects[0].ranges)
        #expect(decoded.snapshot.defaultRangeRawValue == "30d")
        #expect(decoded.snapshot.generatedAt == local.generatedAt)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schemaVersion", "publisherID", "snapshot"])
        let snapshot = try #require(object["snapshot"] as? [String: Any])
        #expect(Set(snapshot.keys) == ["schemaVersion", "generatedAt", "defaultRangeRawValue", "projects"])
        let project = try #require((snapshot["projects"] as? [[String: Any]])?.first)
        #expect(Set(project.keys) == ["id", "name", "symbol", "enabled", "hasError", "ranges"])
        let range = try #require((project["ranges"] as? [[String: Any]])?.first)
        #expect(Set(range.keys) == ["rawValue", "title", "measuredAt", "metrics"])
        let metric = try #require((range["metrics"] as? [[String: Any]])?.first)
        #expect(Set(metric.keys) == ["id", "label", "value"])
    }

    @Test func unknownSourceFieldsCannotBeForwardedByTheTypedSyncBoundary() throws {
        let original = try CloudSyncSnapshot.prepared(publisherID: publisherID, snapshot: fixture(), now: now)
        var object = try #require(JSONSerialization.jsonObject(with: original.encoded(now: now)) as? [String: Any])
        object["credential"] = "private-credential-must-not-be-forwarded"
        object["endpoint"] = "https://private.example.invalid"
        object["query"] = "select sensitive_rows"
        object["breakdowns"] = [["name": "Private person"]]
        let remote = try CloudSyncSnapshot.decode(JSONSerialization.data(withJSONObject: object), now: now)
        #expect(remote == original)
        let forwarded = String(decoding: try remote.encoded(now: now), as: UTF8.self)
        for privateValue in ["private-credential", "private.example", "sensitive_rows", "Private person"] {
            #expect(!forwarded.contains(privateValue))
        }
    }

    @Test func futureInvalidAndInconsistentTimestampsAreRejectedWithoutChangingFreshness() throws {
        var source = fixture()
        source.generatedAt = now.addingTimeInterval(CloudSyncSnapshot.maximumClockSkew + 1)
        #expect(throws: CloudSyncSnapshotError.invalidSnapshot) {
            try CloudSyncSnapshot.prepared(publisherID: publisherID, snapshot: source, now: now)
        }
        source = fixture()
        source.projects[0].ranges[0].measuredAt = now.addingTimeInterval(CloudSyncSnapshot.maximumClockSkew + 1)
        #expect(throws: CloudSyncSnapshotError.invalidSnapshot) {
            try CloudSyncSnapshot.prepared(publisherID: publisherID, snapshot: source, now: now)
        }
        source = fixture(generatedAt: now.addingTimeInterval(-1_000))
        source.projects[0].ranges[0].measuredAt = now
        #expect(throws: CloudSyncSnapshotError.invalidSnapshot) {
            try CloudSyncSnapshot.prepared(publisherID: publisherID, snapshot: source, now: now)
        }
        source = fixture()
        source.generatedAt = Date(timeIntervalSince1970: -1)
        #expect(throws: CloudSyncSnapshotError.invalidSnapshot) {
            try CloudSyncSnapshot.prepared(publisherID: publisherID, snapshot: source, now: now)
        }
        source = fixture()
        source.generatedAt = Date(timeIntervalSince1970: .infinity)
        #expect(throws: WidgetSnapshotError.invalidSnapshot) {
            try CloudSyncSnapshot.prepared(publisherID: publisherID, snapshot: source, now: now)
        }

        let clockSkew = fixture(generatedAt: now.addingTimeInterval(CloudSyncSnapshot.maximumClockSkew))
        let accepted = try CloudSyncSnapshot.prepared(publisherID: publisherID, snapshot: clockSkew, now: now)
        #expect(accepted.snapshot.generatedAt == clockSkew.generatedAt)
        let stale = fixture(generatedAt: now.addingTimeInterval(-365 * 24 * 60 * 60))
        #expect(try CloudSyncSnapshot.prepared(publisherID: publisherID, snapshot: stale, now: now).snapshot.generatedAt == stale.generatedAt)
    }

    @Test func unsupportedVersionsMalformedPayloadsAndIconsFailClosed() throws {
        let unsupported = CloudSyncSnapshot(schemaVersion: 2, publisherID: publisherID, snapshot: fixture())
        #expect(throws: CloudSyncSnapshotError.unsupportedVersion) { try unsupported.encoded(now: now) }
        let unsupportedData = try JSONEncoder().encode(unsupported)
        #expect(throws: CloudSyncSnapshotError.unsupportedVersion) { try CloudSyncSnapshot.decode(unsupportedData, now: now) }
        #expect(throws: (any Error).self) { try CloudSyncSnapshot.decode(Data("{broken".utf8), now: now) }

        let valid = try CloudSyncSnapshot.prepared(publisherID: publisherID, snapshot: fixture(), now: now)
        var object = try #require(JSONSerialization.jsonObject(with: valid.encoded(now: now)) as? [String: Any])
        var snapshot = try #require(object["snapshot"] as? [String: Any])
        var projects = try #require(snapshot["projects"] as? [[String: Any]])
        projects[0]["iconImageData"] = Data([0, 1, 2]).base64EncodedString()
        snapshot["projects"] = projects
        object["snapshot"] = snapshot
        let iconData = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CloudSyncSnapshotError.invalidSnapshot) { try CloudSyncSnapshot.decode(iconData, now: now) }
    }

    @Test func syncBoundIsEnforcedBeforeDecodeAndAfterEncode() throws {
        #expect(throws: CloudSyncSnapshotError.snapshotTooLarge) {
            try CloudSyncSnapshot.decode(Data(repeating: 0x20, count: CloudSyncSnapshot.maximumEncodedBytes + 1), now: now)
        }
        var source = fixture()
        source.projects = (0..<50).map { index in
            WidgetProject(id: UUID(), name: "Project \(index)", symbol: "calendar", ranges: [
                WidgetRange(rawValue: "30d", title: "30d", measuredAt: now, metrics: [
                    WidgetMetric(id: UUID(), label: String(repeating: "\u{0000}", count: 256), value: String(repeating: "\u{0000}", count: 256))
                ])
            ])
        }
        try source.validate()
        #expect(throws: CloudSyncSnapshotError.snapshotTooLarge) {
            try CloudSyncSnapshot.prepared(publisherID: publisherID, snapshot: source, now: now)
        }
    }

    @Test func newestSamePublisherWinsAndEqualOrOlderCompletionsCannotReviveProjects() throws {
        let older = try CloudSyncSnapshot.prepared(publisherID: publisherID, snapshot: fixture(generatedAt: now.addingTimeInterval(-60)), now: now)
        let empty = WidgetSnapshot(generatedAt: now, defaultRangeRawValue: "30d", projects: [])
        let newer = try CloudSyncSnapshot.prepared(publisherID: publisherID, snapshot: empty, now: now)
        #expect(try newer.preferred(over: older, now: now) == newer)
        #expect(try older.preferred(over: newer, now: now) == newer)
        #expect(try newer.preferred(over: nil, now: now) == newer)
        let equalTimestamp = try CloudSyncSnapshot.prepared(publisherID: publisherID, snapshot: fixture(), now: now)
        #expect(try equalTimestamp.preferred(over: newer, now: now) == newer)

        let anotherMac = try CloudSyncSnapshot.prepared(publisherID: UUID(), snapshot: fixture(), now: now)
        #expect(throws: CloudSyncSnapshotError.publisherMismatch) { try anotherMac.preferred(over: newer, now: now) }
    }
}
