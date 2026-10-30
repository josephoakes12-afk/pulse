import Foundation
import Testing
@testable import PulseWidgetData

struct CloudSyncRemovalTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let publisherID = UUID(uuidString: "AA90660F-2568-4C35-A654-469BFEC8F343")!
    private let fenceID = UUID(uuidString: "907970B6-0A23-4563-ABFC-0221BD352425")!

    private func summary(publisherID: UUID? = nil, date: Date? = nil) throws -> CloudSyncSnapshot {
        let date = date ?? now
        return try CloudSyncSnapshot.prepared(publisherID: publisherID ?? self.publisherID,
            snapshot: WidgetSnapshot(generatedAt: date, defaultRangeRawValue: "30d", projects: [
                WidgetProject(id: UUID(), name: "Private studio", symbol: "calendar", ranges: [
                    WidgetRange(rawValue: "30d", title: "30d", measuredAt: date, metrics: [
                        WidgetMetric(id: UUID(), label: "Private KPI", value: "1234")
                    ])
                ])
            ]), now: now)
    }

    @Test func removalContainsNoProjectsNumbersNamesOrOriginalPublisher() throws {
        let current = try summary()
        let marker = try CloudSyncRemovalPolicy.marker(current: current, confirmedPublisherID: publisherID,
            removalPublisherID: fenceID, now: now)
        #expect(marker.isCleared)
        #expect(marker.publisherID == fenceID)
        #expect(marker.snapshot.projects.isEmpty)
        #expect(marker.snapshot.defaultRangeRawValue == "7d")
        let data = try marker.encoded(now: now)
        #expect(try CloudSyncSnapshot.decode(data, now: now) == marker)
        let text = String(decoding: data, as: UTF8.self)
        for removed in ["Private studio", "Private KPI", "1234", publisherID.uuidString] {
            #expect(!text.contains(removed))
        }
        #expect(data.count < 512)
    }

    @Test func aChangedOwnerCannotBeRemovedWithAnEarlierConfirmation() throws {
        let anotherOwner = try summary(publisherID: UUID())
        #expect(throws: CloudSyncSnapshotError.publisherMismatch) {
            try CloudSyncRemovalPolicy.marker(current: anotherOwner, confirmedPublisherID: publisherID,
                removalPublisherID: fenceID, now: now)
        }
        // A missing record still gets a fence so a delayed old create cannot
        // resurrect the data after the removal operation finishes.
        let missing = try CloudSyncRemovalPolicy.marker(current: nil, confirmedPublisherID: publisherID,
            removalPublisherID: fenceID, now: now)
        #expect(missing.isCleared && missing.snapshot.projects.isEmpty)
        #expect(throws: CloudSyncSnapshotError.invalidSnapshot) {
            try CloudSyncRemovalPolicy.marker(current: nil, confirmedPublisherID: publisherID,
                removalPublisherID: publisherID, now: now)
        }
    }

    @Test func aFormerCollectorCannotRepublishEvenWithANewerClockOrMissingLocalRemovalState() throws {
        let previous = try summary()
        let marker = try CloudSyncRemovalPolicy.marker(current: previous, confirmedPublisherID: publisherID,
            removalPublisherID: fenceID, now: now)
        let clockAhead = try summary(date: now.addingTimeInterval(240))
        #expect(try CloudSyncPolicy.decision(enabled: true, boundAccountID: "a", actualAccountID: "a",
            local: clockAhead, remote: marker, publisherID: publisherID, now: now) == .receive(marker))
        #expect(try CloudSyncPolicy.decision(enabled: true, boundAccountID: "a", actualAccountID: "a",
            local: previous, remote: marker, publisherID: publisherID, replacingPublisherID: UUID(), now: now) == .receive(marker))
        #expect(try CloudSyncPolicy.decision(enabled: true, boundAccountID: "a", actualAccountID: "a",
            local: previous, remote: marker, publisherID: publisherID, replacingPublisherID: fenceID, now: now)
            == .publish(previous, replacingPublisherID: fenceID))
        #expect(try CloudSyncPolicy.decision(enabled: true, boundAccountID: "a", actualAccountID: "b",
            local: previous, remote: marker, publisherID: publisherID, replacingPublisherID: fenceID, now: now) == .pausedAccountChange)
    }

    @Test func removedFlagCannotHideRetainedProjectsAndLegacyClientsStillSeeAnEmptyForeignSummary() throws {
        let current = try summary()
        let invalid = CloudSyncSnapshot(publisherID: fenceID, snapshot: current.snapshot, isCleared: true)
        #expect(throws: CloudSyncSnapshotError.invalidSnapshot) { try invalid.encoded(now: now) }
        #expect(throws: CloudSyncSnapshotError.invalidSnapshot) {
            try CloudSyncSnapshot.decode(JSONEncoder().encode(invalid), now: now)
        }
        let marker = try CloudSyncRemovalPolicy.marker(current: current, confirmedPublisherID: publisherID,
            removalPublisherID: fenceID, now: now)
        struct LegacySnapshot: Decodable {
            var schemaVersion: Int
            var publisherID: UUID
            var snapshot: WidgetSnapshot
        }
        let legacy = try JSONDecoder().decode(LegacySnapshot.self, from: marker.encoded(now: now))
        #expect(legacy.schemaVersion == CloudSyncSnapshot.currentSchemaVersion)
        #expect(legacy.publisherID != publisherID)
        #expect(legacy.snapshot.projects.isEmpty)
    }
}
