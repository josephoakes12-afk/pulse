import Foundation
import Testing
@testable import PulseCore

/// Opt-in, local synthetic fixture. The server is owned by the invoking QA run;
/// this test never provisions or modifies a database or connects by default.
@Test func postgresAnalyticsAgainstLocalSyntheticFixture() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["PULSE_TEST_POSTGRES_URL"] else { return }
    let secret = ProcessInfo.processInfo.environment["PULSE_TEST_POSTGRES_PASSWORD"]
    guard let host = URLComponents(string: endpoint)?.host, ConnectorValidation.isLoopback(host) else {
        Issue.record("The PostgreSQL analytics fixture must be local.")
        return
    }
    let connector = PostgresConnector()
    let base = ProjectConnection(name: "Synthetic fixture", kind: .postgres, endpoint: endpoint)
    let tables = try await connector.discoverTables(connection: base, secret: secret)
    #expect(tables.contains { $0.schema == "public" && $0.name == "users" })
    #expect(tables.contains { $0.schema == "public" && $0.name == "bookings" })
    #expect(!tables.contains { $0.schema == "hidden" })
    let relationships = try await connector.discoverRelationships(connection: base, secret: secret, tables: tables)
    let publicRelationship = try #require(relationships.first { $0.child.schema == "public" && $0.child.name == "bookings" && $0.parent.name == "users" })
    #expect(publicRelationship.childColumn == "user_id")
    #expect(publicRelationship.parentColumn == "id")
    #expect(publicRelationship.parentLabelColumn == "name")
    let selected = [publicRelationship.parent, publicRelationship.child]
    #expect(PostgresConnector.recommendedTables(from: relationships) == selected)
    let counted = try PostgresConnector.countingConnection(base: base, tables: selected)
    let configured = PostgresConnector.configureAnalytics(base: counted, tables: selected, relationships: relationships)
    let snapshot = try await connector.collect(connection: configured, secret: secret)
    #expect(snapshot.metrics.map(\.value) == ["14", "38"])
    #expect(snapshot.details?.first { $0.label == "Avg. bookings / user" }?.value == "2.6")
    #expect(snapshot.details?.first { $0.label == "Users with bookings" }?.value == "9")
    #expect(snapshot.details?.first { $0.label == "Unlinked bookings" }?.value == "1")
    let breakdown = try #require(snapshot.breakdowns?.first)
    #expect(breakdown.title == "Bookings by user")
    #expect(breakdown.truncated)
    #expect(breakdown.rows.count == 10)
    #expect(Set(breakdown.rows.map(\.id)).count == 10)
    #expect(breakdown.rows.filter { $0.label == "Shared name" }.count == 2)
    #expect(breakdown.rows.contains { $0.value == "0" })

    let usersOnly = try PostgresConnector.selectedCountingConnection(base: configured, metricPaths: ["metric_0"])
    let usersSnapshot = try await connector.collect(connection: usersOnly, secret: secret)
    #expect(usersSnapshot.metrics.map(\.label) == ["Users"])
    #expect(usersSnapshot.metrics.map(\.value) == ["14"])
    #expect(usersSnapshot.breakdowns?.isEmpty != false)
    let bookingsOnly = try PostgresConnector.selectedCountingConnection(base: configured, metricPaths: ["metric_1"])
    let bookingsSnapshot = try await connector.collect(connection: bookingsOnly, secret: secret)
    #expect(bookingsSnapshot.metrics.map(\.label) == ["Bookings"])
    #expect(bookingsSnapshot.metrics.map(\.value) == ["38"])
    #expect(bookingsSnapshot.breakdowns?.first?.title == "Bookings by user")
    #expect(bookingsSnapshot.details?.first { $0.label == "Avg. bookings / user" }?.value == "2.6")

    // An optional label disappeared after discovery: the savepoint fallback
    // must still deliver the established headline numbers.
    var outdated = configured
    var badRelationship = publicRelationship
    badRelationship.parentLabelColumn = "display_name"
    outdated.autoStats = DatabaseAnalyticsPlan(relationships: [badRelationship])
    let fallback = try await connector.collect(connection: outdated, secret: secret)
    #expect(fallback.metrics.map(\.value) == ["14", "38"])
    #expect(fallback.breakdowns?.isEmpty != false)

    let emptyRelationship = try #require(relationships.first { $0.child.schema == "empty_data" && $0.child.name == "bookings" })
    let emptyTables = [emptyRelationship.parent, emptyRelationship.child]
    let emptyCounted = try PostgresConnector.countingConnection(base: base, tables: emptyTables)
    let emptyConfigured = PostgresConnector.configureAnalytics(base: emptyCounted, tables: emptyTables, relationships: relationships)
    let emptySnapshot = try await connector.collect(connection: emptyConfigured, secret: secret)
    #expect(emptySnapshot.metrics.map(\.value) == ["0", "0"])
    #expect(emptySnapshot.details?.first { $0.label == "Avg. bookings / user" }?.value == "—")
    #expect(emptySnapshot.breakdowns?.first?.rows.isEmpty != false)
}
