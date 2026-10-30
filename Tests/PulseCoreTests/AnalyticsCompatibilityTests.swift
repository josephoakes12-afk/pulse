import Foundation
import Testing
@testable import PulseCore

@Test func oldConnectionsAndCachedSnapshotsStillDecodeWithoutAnalyticsFields() throws {
    let profile = Data(#"{"id":"10000000-0000-0000-0000-000000000001","name":"Existing project","symbol":"calendar","kind":"http","endpoint":"https://example.com/api/summary","query":"","authHeader":"Authorization","credentialVersion":"20000000-0000-0000-0000-000000000001","metrics":[{"id":"30000000-0000-0000-0000-000000000001","label":"Users","path":"users"}],"intervalSeconds":300,"notificationsEnabled":false,"enabled":true,"link":""}"#.utf8)
    let connection = try JSONDecoder().decode(ProjectConnection.self, from: profile)
    #expect(connection.name == "Existing project")
    #expect(connection.autoStats == nil)
    #expect(connection.sourceTables == nil)
    let cached = Data(#"{"projectID":"10000000-0000-0000-0000-000000000001","metrics":[{"id":"30000000-0000-0000-0000-000000000001","label":"Users","value":"12"}],"events":[],"measuredAt":0,"fetchedAt":0}"#.utf8)
    let snapshot = try JSONDecoder().decode(ProjectSnapshot.self, from: cached)
    #expect(snapshot.metrics.first?.value == "12")
    #expect(snapshot.details == nil)
    #expect(snapshot.breakdowns == nil)
}

@Test func cachedDrilldownsRetainDistinctIdentitiesAndTheirScope() throws {
    let project = UUID()
    let original = ProjectSnapshot(projectID: project, metrics: [], details: [MetricValue(id: MetricIdentity.uuid(projectID: project, path: "avg"), label: "Avg. bookings / user", value: "2.6")], breakdowns: [MetricBreakdown(id: "users", title: "Bookings by user", rows: [MetricBreakdownRow(id: "u1", label: "Shared name", value: "8"), MetricBreakdownRow(id: "u2", label: "Shared name", value: "5")], truncated: true)])
    let restored = try JSONDecoder().decode(ProjectSnapshot.self, from: JSONEncoder().encode(original))
    #expect(restored == original)
    #expect(restored.breakdowns?.first?.rows.count == 2)
    #expect(restored.breakdowns?.first?.truncated == true)
}
