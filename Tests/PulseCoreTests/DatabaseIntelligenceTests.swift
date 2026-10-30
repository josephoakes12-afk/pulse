import Foundation
import Testing
@testable import PulseCore

private let intelligenceUsers = DatabaseTable(schema: "public", name: "users", isView: false)
private let intelligenceBookings = DatabaseTable(schema: "public", name: "bookings", isView: false)
private let intelligenceRelationship = DatabaseRelationship(child: intelligenceBookings, childColumn: "user_id", parent: intelligenceUsers, parentColumn: "id")

@Suite struct DatabaseIntelligenceTests {
    @Test func legacyPlansStillDecodeAndKeepTheirThreeOriginalMetrics() throws {
        let old = DatabaseAnalyticsPlan(relationships: [intelligenceRelationship])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "columns")
        let decoded = try JSONDecoder().decode(DatabaseAnalyticsPlan.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.version == 1)
        #expect(decoded.columns == nil)
        var connection = ProjectConnection(name: "Example", kind: .postgres, endpoint: "postgresql://reader@localhost/app", query: "SELECT 1 AS total", metrics: [MetricDefinition(label: "Total", path: "total")])
        connection.autoStats = decoded
        let query = try DatabaseAnalytics.queryWithAnalytics(connection)
        #expect(query.contains("'relationship_0.average'"))
        #expect(query.contains("'relationship_0.active'"))
        #expect(query.contains("'relationship_0.unlinked'"))
        #expect(!query.contains(".coverage'"))
        #expect(query.contains("SELECT 1 AS total"))
    }

    @Test func genericRelationshipsExposeTotalsInactivityMaximumAndCoverage() throws {
        let projects = DatabaseTable(schema: "public", name: "projects", isView: false)
        let deployments = DatabaseTable(schema: "public", name: "deployments", isView: false)
        let relationship = DatabaseRelationship(child: deployments, childColumn: "project_id", parent: projects, parentColumn: "id", parentLabelColumn: "name")
        let base = try PostgresConnector.countingConnection(base: ProjectConnection(name: "Example", kind: .postgres, endpoint: "postgresql://reader@localhost/app"), tables: [projects, deployments])
        let configured = PostgresConnector.configureAnalytics(base: base, tables: [projects, deployments], relationships: [relationship])
        #expect(configured.autoStats?.version == 2)
        let query = try DatabaseAnalytics.queryWithAnalytics(configured)
        for expected in ["Total projects", "Total deployments", "Projects without deployments", "Max. deployments / project", "Projects with deployments %", "parents - active", "max(quantity)", "active::numeric * 100 / parents", "LIMIT 24", "LIMIT 10"] {
            #expect(query.contains(expected))
        }
        #expect(query.contains(DatabaseAnalytics.relationshipID(relationship) + ".maximum"))
        #expect(query.contains(base.query))
        #expect(query.contains("LEFT JOIN pulse_child_counts"))
        #expect(query.contains("ELSE '—' END"))
    }

    @Test func columnEvidenceAddsUsefulFactsWithoutAForeignKey() throws {
        let columns = [
            DatabaseColumn(table: intelligenceUsers, name: "created_at", kind: .timestamp),
            DatabaseColumn(table: intelligenceUsers, name: "enabled", kind: .boolean),
            DatabaseColumn(table: intelligenceUsers, name: "status", kind: .enumeration, enumValues: ["trial", "active", "cancelled"])
        ]
        let base = try PostgresConnector.countingConnection(base: ProjectConnection(name: "Example", kind: .postgres, endpoint: "postgresql://reader@localhost/app"), tables: [intelligenceUsers])
        let configured = PostgresConnector.configureAnalytics(base: base, tables: [intelligenceUsers], relationships: [], columns: columns)
        #expect(configured.autoStats?.relationships.isEmpty == true)
        let query = try DatabaseAnalytics.queryWithAnalytics(configured)
        for expected in ["New users · 24h", "New users · 7d", "New users · 30d", "IS TRUE", "IS FALSE", "CURRENT_TIMESTAMP", "interval '24 hours'", "interval '168 hours'", "interval '720 hours'", "<= CURRENT_TIMESTAMP", "Users by status · total", "'active'", "Total users"] {
            #expect(query.contains(expected))
        }
        #expect(!query.contains("SELECT DISTINCT c."))
        #expect(query.contains("SELECT DISTINCT ON (pulse_item->>'id')"))
        #expect(!query.contains("SUM("))
        #expect(configured.query == base.query)
    }

    @Test func discoveryIsBoundedMetadataOnlyAndDoesNotGuessLocalTimezonesOrMoney() throws {
        let query = try DatabaseAnalytics.columnDiscoveryQuery(tables: [intelligenceUsers, intelligenceBookings])
        for expected in ["pg_catalog.pg_attribute", "pg_catalog.pg_enum", "has_column_privilege", "timestamptz", "BETWEEN 1 AND 8", "LIMIT 48", "AS pulse_column"] {
            #expect(query.contains(expected))
        }
        #expect(!query.contains("FROM \"public\".\"users\""))
        #expect(!query.contains("FROM \"public\".\"bookings\""))
        #expect(!query.contains("'timestamp' AND"))
        #expect(!query.contains("revenue"))
        #expect(throws: PulseError.self) { try DatabaseAnalytics.columnDiscoveryQuery(tables: []) }
    }

    @Test func privateAndAmbiguousMetadataIsNotAnAutomaticCandidate() throws {
        let base = ProjectConnection(name: "Example", kind: .postgres)
        let invalid = [
            DatabaseColumn(table: intelligenceUsers, name: "access_token", kind: .boolean),
            DatabaseColumn(table: intelligenceUsers, name: "updated_at", kind: .timestamp),
            DatabaseColumn(table: intelligenceUsers, name: "status", kind: .enumeration, enumValues: []),
            DatabaseColumn(table: intelligenceUsers, name: "email_status", kind: .enumeration, enumValues: ["verified"])
        ]
        #expect(DatabaseAnalytics.configure(base: base, tables: [intelligenceUsers], relationships: [], columns: invalid).autoStats == nil)
        let privateOther = DatabaseTable(schema: "hidden", name: "secrets", isView: false)
        #expect(DatabaseAnalytics.configure(base: base, tables: [intelligenceUsers], relationships: [], columns: [DatabaseColumn(table: privateOther, name: "enabled", kind: .boolean)]).autoStats == nil)
        let ambiguous = DatabaseRelationship(child: intelligenceBookings, childColumn: "created_by", parent: intelligenceUsers, parentColumn: "id")
        #expect(DatabaseAnalytics.configure(base: base, tables: [intelligenceBookings], relationships: [intelligenceRelationship, ambiguous]).autoStats == nil)
    }

    @Test func existingRelationshipOrderAndLegacyIdentitiesSurviveANewRelationship() throws {
        let services = DatabaseTable(schema: "public", name: "services", isView: false)
        let added = DatabaseRelationship(child: intelligenceBookings, childColumn: "service_id", parent: services, parentColumn: "id")
        var base = ProjectConnection(name: "Example", kind: .postgres, query: "SELECT 1 AS total", metrics: [MetricDefinition(label: "Total", path: "total")])
        base.autoStats = DatabaseAnalyticsPlan(relationships: [intelligenceRelationship])
        let configured = DatabaseAnalytics.configure(base: base, tables: [intelligenceBookings], relationships: [added, intelligenceRelationship])
        #expect(configured.autoStats?.relationships.first == intelligenceRelationship)
        #expect(configured.autoStats?.relationships.count == 2)
        let query = try DatabaseAnalytics.queryWithAnalytics(configured)
        #expect(query.contains("'relationship_0.average'"))
        #expect(query.contains("table:" + services.id + ".total"))
        var relabelled = intelligenceRelationship
        relabelled.parentLabelColumn = "name"
        let updated = DatabaseAnalytics.configure(base: base, tables: [intelligenceBookings], relationships: [added, relabelled])
        #expect(updated.autoStats?.relationships.first == relabelled)
    }

    @Test func enumLiteralsStayDataAndRemovedTablesLoseTheirFacts() throws {
        let status = DatabaseColumn(table: intelligenceUsers, name: "status", kind: .enumeration, enumValues: ["draft'; DROP TABLE users; --", "active"])
        let base = try PostgresConnector.countingConnection(base: ProjectConnection(name: "Example", kind: .postgres, endpoint: "postgresql://reader@localhost/app"), tables: [intelligenceUsers, intelligenceBookings])
        let configured = PostgresConnector.configureAnalytics(base: base, tables: [intelligenceUsers, intelligenceBookings], relationships: [intelligenceRelationship], columns: [status])
        let query = try DatabaseAnalytics.queryWithAnalytics(configured)
        #expect(query.contains("= 'draft''; DROP TABLE users; --'"))
        // Explicit escape literals remain data even on a server configured with
        // standard_conforming_strings=off.
        #expect(DatabaseAnalytics.literal("draft\\'; SELECT secret") == "E'draft\\\\''; SELECT secret'")
        let reduced = try PostgresConnector.countingConnection(base: configured, tables: [intelligenceBookings])
        #expect(reduced.autoStats?.columns == nil)
        #expect(reduced.autoStats?.relationships == [intelligenceRelationship])
    }

    /// The caller may execute these SELECT-only queries on PostgreSQL without
    /// creating objects or reading any real source rows.
    @Test func exportExactReadOnlyIntelligenceFixturesWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["PULSE_INTELLIGENCE_SQL_EXPORT"] else { return }
        let base = try PostgresConnector.countingConnection(base: ProjectConnection(name: "Synthetic fixture", kind: .postgres, endpoint: "postgresql://reader@localhost/app"), tables: [intelligenceUsers, intelligenceBookings])
        let columns = [
            DatabaseColumn(table: intelligenceUsers, name: "created_at", kind: .timestamp),
            DatabaseColumn(table: intelligenceUsers, name: "enabled", kind: .boolean),
            DatabaseColumn(table: intelligenceUsers, name: "status", kind: .enumeration, enumValues: ["trial", "active", "cancelled"]),
            DatabaseColumn(table: intelligenceBookings, name: "created_at", kind: .timestamp)
        ]
        let configured = PostgresConnector.configureAnalytics(base: base, tables: [intelligenceUsers, intelligenceBookings], relationships: [intelligenceRelationship], columns: columns)
        let exact = try DatabaseAnalytics.queryWithAnalytics(configured)
            .replacingOccurrences(of: #""public"."users""#, with: "pulse_fixture_users")
            .replacingOccurrences(of: #""public"."bookings""#, with: "pulse_fixture_bookings")
        let users = """
        VALUES ('u1'::text, true, 'active'::text, CURRENT_TIMESTAMP - interval '1 hour'),
               ('u2'::text, false, 'cancelled'::text, CURRENT_TIMESTAMP - interval '48 hours'),
               ('u3'::text, NULL::boolean, 'active'::text, CURRENT_TIMESTAMP - interval '960 hours')
        """
        let bookings = """
        VALUES (1::bigint, 'u1'::text, CURRENT_TIMESTAMP - interval '1 hour'),
               (2::bigint, 'u1'::text, CURRENT_TIMESTAMP - interval '48 hours'),
               (3::bigint, 'u2'::text, CURRENT_TIMESTAMP - interval '240 hours'),
               (4::bigint, NULL::text, CURRENT_TIMESTAMP + interval '1 hour')
        """
        let noUsers = "SELECT NULL::text, NULL::boolean, NULL::text, CURRENT_TIMESTAMP WHERE false"
        let noBookings = "SELECT NULL::bigint, NULL::text, CURRENT_TIMESTAMP WHERE false"
        let orphan = "VALUES (1::bigint, NULL::text, CURRENT_TIMESTAMP - interval '1 hour')"
        let cases: [(String, String, String, [String: String])] = [
            ("normal", users, bookings, ["metric_0": "3", "metric_1": "4", "Avg. bookings / user": "1.0", "Users with bookings": "2", "Unlinked bookings": "1", "Users without bookings · total": "1", "Max. bookings / user · total": "2", "Users with bookings % · total": "66.7%", "New bookings · 24h": "1", "New bookings · 7d": "2", "New bookings · 30d": "3", "New users · 24h": "1", "New users · 7d": "2", "New users · 30d": "2", "Users · Enabled yes · total": "1", "Users · Enabled no · total": "1", "Users · active · total": "2", "Users · cancelled · total": "1", "Users · trial · total": "0"]),
            ("empty", noUsers, noBookings, ["metric_0": "0", "metric_1": "0", "Avg. bookings / user": "—", "Users with bookings": "0", "Unlinked bookings": "0", "Users without bookings · total": "0", "Max. bookings / user · total": "0", "Users with bookings % · total": "—"]),
            ("unlinked_only", noUsers, orphan, ["metric_0": "0", "metric_1": "1", "Avg. bookings / user": "—", "Unlinked bookings": "1", "Max. bookings / user · total": "0", "Users with bookings % · total": "—", "New bookings · 24h": "1"]),
            ("zero_children", users, noBookings, ["metric_0": "3", "metric_1": "0", "Avg. bookings / user": "0.0", "Users with bookings": "0", "Unlinked bookings": "0", "Users without bookings · total": "3", "Max. bookings / user · total": "0", "Users with bookings % · total": "0.0%"])
        ]
        let exported = cases.map { name, parentRows, childRows, expected -> [String: Any] in
            let query = """
            WITH pulse_fixture_users(id, enabled, status, created_at) AS (\(parentRows)),
                 pulse_fixture_bookings(id, user_id, created_at) AS (\(childRows))
            SELECT row_to_json(pulse_result) AS result FROM (\(exact)) AS pulse_result
            """
            return ["name": name, "query": query, "expected": expected]
        }
        try JSONSerialization.data(withJSONObject: exported, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
