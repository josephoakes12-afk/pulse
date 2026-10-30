import Foundation
import Testing
@testable import PulseCore

private let analyticsUsers = DatabaseTable(schema: "public", name: "users", isView: false)
private let analyticsBookings = DatabaseTable(schema: "public", name: "bookings", isView: false)
private func analyticsRelationship(column: String = "user_id", label: String? = "display_name") -> DatabaseRelationship {
    DatabaseRelationship(child: analyticsBookings, childColumn: column, parent: analyticsUsers, parentColumn: "id", parentLabelColumn: label)
}
private func analyticsBase() -> ProjectConnection {
    ProjectConnection(name: "Example", kind: .postgres, endpoint: "postgresql://reader@localhost/app")
}

@Test func automaticAnalyticsRequiresAnUnambiguousDeclaredRelationship() throws {
    let tables = [analyticsUsers, analyticsBookings]
    let one = analyticsRelationship()
    let configured = PostgresConnector.configureAnalytics(base: analyticsBase(), tables: tables, relationships: [one])
    #expect(configured.autoStats?.relationships == [one])
    #expect(configured.sourceTables == tables)
    let ambiguous = PostgresConnector.configureAnalytics(base: analyticsBase(), tables: tables, relationships: [one, analyticsRelationship(column: "created_by")])
    #expect(ambiguous.autoStats == nil)
    let childOnly = PostgresConnector.configureAnalytics(base: analyticsBase(), tables: [analyticsBookings], relationships: [one])
    #expect(childOnly.autoStats?.relationships == [one])
    #expect(PostgresConnector.configureAnalytics(base: analyticsBase(), tables: tables, relationships: []).autoStats == nil)
}

@Test func automaticRecommendationsOnlySelectOneConfidentDomainPair() {
    #expect(PostgresConnector.recommendedTables(from: [analyticsRelationship()]) == [analyticsUsers, analyticsBookings])
    #expect(PostgresConnector.recommendedTables(from: [analyticsRelationship(), analyticsRelationship(column: "created_by")]).isEmpty)
    let unexpected = DatabaseRelationship(child: DatabaseTable(schema: "public", name: "arbitrary_log", isView: false), childColumn: "user_id", parent: analyticsUsers, parentColumn: "id")
    #expect(PostgresConnector.recommendedTables(from: [unexpected]) == [analyticsUsers, unexpected.child])
}

@Test func automaticRecommendationsCoverGenericProjectDomains() throws {
    let projects = DatabaseTable(schema: "public", name: "projects", isView: false)
    let deployments = DatabaseTable(schema: "public", name: "deployments", isView: false)
    let teams = DatabaseTable(schema: "public", name: "teams", isView: false)
    let messages = DatabaseTable(schema: "public", name: "messages", isView: false)
    let deploymentRelationship = DatabaseRelationship(child: deployments, childColumn: "project_id", parent: projects, parentColumn: "id", parentLabelColumn: "name")
    let messageRelationship = DatabaseRelationship(child: messages, childColumn: "team_id", parent: teams, parentColumn: "id", parentLabelColumn: "name")
    for relationship in [deploymentRelationship, messageRelationship] {
        let selected = PostgresConnector.recommendedTables(from: [relationship])
        #expect(selected == [relationship.parent, relationship.child])
        let counted = try PostgresConnector.countingConnection(base: analyticsBase(), tables: selected)
        let configured = PostgresConnector.configureAnalytics(base: counted, tables: selected, relationships: [relationship])
        let query = try PostgresConnector.queryWithAnalytics(configured)
        let expectedChild = relationship.child.name
        let expectedParent = String(relationship.parent.name.dropLast())
        #expect(query.contains("Avg. \(expectedChild) / \(expectedParent)"))
        #expect(query.contains(ProjectSetup.friendlyLabel(expectedChild) + " by " + expectedParent))
        #expect(query.contains("LEFT JOIN pulse_child_counts"))
        #expect(query.contains("LEFT JOIN pulse_child_counts AS c ON c.parent_id = p.\"id\""))
    }
    #expect(PostgresConnector.recommendedTables(from: [deploymentRelationship, messageRelationship]).isEmpty)
    let alternateTeamRelationship = DatabaseRelationship(child: messages, childColumn: "review_team_id", parent: teams, parentColumn: "id")
    #expect(PostgresConnector.recommendedTables(from: [messageRelationship, alternateTeamRelationship]).isEmpty)
}

@Test func automaticRecommendationsRespectPublicScopeBeforeGenericFallback() {
    let deployments = DatabaseTable(schema: "public", name: "deployments", isView: false)
    let projects = DatabaseTable(schema: "public", name: "projects", isView: false)
    let publicGeneric = DatabaseRelationship(child: deployments, childColumn: "project_id", parent: projects, parentColumn: "id")
    let privateBookings = DatabaseRelationship(child: DatabaseTable(schema: "archive", name: "bookings", isView: false), childColumn: "user_id", parent: DatabaseTable(schema: "archive", name: "users", isView: false), parentColumn: "id")
    #expect(PostgresConnector.recommendedTables(from: [privateBookings, publicGeneric]) == [projects, deployments])
}

@Test func genericAnalyticsUsesSimpleIrregularPersonLabels() throws {
    let people = DatabaseTable(schema: "public", name: "people", isView: false)
    let contributions = DatabaseTable(schema: "public", name: "contributions", isView: false)
    let relationship = DatabaseRelationship(child: contributions, childColumn: "person_id", parent: people, parentColumn: "id")
    let counted = try PostgresConnector.countingConnection(base: analyticsBase(), tables: [contributions])
    let configured = PostgresConnector.configureAnalytics(base: counted, tables: [contributions], relationships: [relationship])
    let query = try PostgresConnector.queryWithAnalytics(configured)
    #expect(query.contains("Avg. contributions / person"))
    #expect(query.contains("Contributions by person"))
    #expect(query.contains("'Person ' || left(p.\"id\"::text, 8)"))
}

@Test func automaticSQLPreservesZeroCountParentsAndUnlinkedChildren() throws {
    let counted = try PostgresConnector.countingConnection(base: analyticsBase(), tables: [analyticsUsers, analyticsBookings])
    let configured = PostgresConnector.configureAnalytics(base: counted, tables: [analyticsUsers, analyticsBookings], relationships: [analyticsRelationship()])
    let query = try PostgresConnector.queryWithAnalytics(configured)
    #expect(query.contains("LEFT JOIN pulse_child_counts"))
    #expect(query.contains("count(*)::bigint AS parents"))
    #expect(query.contains("linked::numeric / parents"))
    #expect(query.contains("all_children - linked"))
    #expect(query.contains("ELSE '—' END"))
    #expect(query.contains("LIMIT 10"))
    #expect(query.contains("'truncated', parents > 10"))
    #expect(query.contains("__pulse_details"))
    #expect(query.contains("__pulse_breakdowns"))
    #expect(query.contains(counted.query))
    #expect(query.contains("Avg. bookings / user"))
    #expect(query.contains("Bookings by user"))
    // Allows the local PostgreSQL fixture to run this exact generated SQL,
    // rather than a separately retyped approximation of it.
    if let path = ProcessInfo.processInfo.environment["PULSE_ANALYTICS_SQL_EXPORT"] {
        try query.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

@Test func automaticSQLQuotesIdentifiersAndRejectsPersonalContactLabels() throws {
    let parent = DatabaseTable(schema: "Sales Team", name: "user\"accounts", isView: false)
    let child = DatabaseTable(schema: "Sales Team", name: "book\"ings", isView: false)
    let relation = DatabaseRelationship(child: child, childColumn: "owner\"id", parent: parent, parentColumn: "id")
    var base = analyticsBase()
    base.query = "SELECT 1 AS total"
    base.metrics = [MetricDefinition(label: "Total", path: "total")]
    base.autoStats = DatabaseAnalyticsPlan(relationships: [relation])
    let query = try PostgresConnector.queryWithAnalytics(base)
    #expect(query.contains(#""Sales Team"."book""ings""#))
    #expect(query.contains(#"c."owner""id""#))
    #expect(!query.contains("email"))
    base.autoStats = DatabaseAnalyticsPlan(relationships: [analyticsRelationship(label: "email")])
    #expect(throws: PulseError.self) { try PostgresConnector.queryWithAnalytics(base) }
    base.autoStats = DatabaseAnalyticsPlan(relationships: [analyticsRelationship(column: "bad\u{1}column")])
    #expect(throws: PulseError.self) { try PostgresConnector.queryWithAnalytics(base) }
}

@Test func countingChangesDropPlansOutsideTheRemainingSelection() throws {
    let configured = PostgresConnector.configureAnalytics(base: analyticsBase(), tables: [analyticsUsers, analyticsBookings], relationships: [analyticsRelationship()])
    let reduced = try PostgresConnector.countingConnection(base: configured, tables: [analyticsUsers])
    #expect(reduced.autoStats == nil)
    #expect(reduced.sourceTables == [analyticsUsers])
    let retained = try PostgresConnector.countingConnection(base: configured, tables: [analyticsUsers, analyticsBookings])
    #expect(retained.autoStats?.relationships == [analyticsRelationship()])
    let childOnly = try PostgresConnector.countingConnection(base: configured, tables: [analyticsBookings])
    #expect(childOnly.autoStats?.relationships == [analyticsRelationship()])
}

@Test func selectingHeadlineCountsFollowsPreviewOrderInsteadOfCatalogOrder() throws {
    let relationships = [analyticsRelationship()]
    let recommended = PostgresConnector.recommendedTables(from: relationships)
    let catalogOrder = [analyticsBookings, analyticsUsers]
    #expect(recommended == [analyticsUsers, analyticsBookings])
    #expect(catalogOrder != recommended)
    let counted = try PostgresConnector.countingConnection(base: analyticsBase(), tables: recommended)
    let preview = PostgresConnector.configureAnalytics(base: counted, tables: recommended, relationships: relationships)

    let usersOnly = try PostgresConnector.selectedCountingConnection(base: preview, metricPaths: ["metric_0"])
    #expect(usersOnly.sourceTables == [analyticsUsers])
    #expect(usersOnly.metrics.map(\.label) == ["Users"])
    #expect(usersOnly.metrics.map(\.path) == ["metric_0"])
    #expect(usersOnly.query == #"SELECT (SELECT count(*) FROM "public"."users") AS metric_0"#)
    #expect(usersOnly.autoStats == nil)

    let bookingsOnly = try PostgresConnector.selectedCountingConnection(base: preview, metricPaths: ["metric_1"])
    #expect(bookingsOnly.sourceTables == [analyticsBookings])
    #expect(bookingsOnly.metrics.map(\.label) == ["Bookings"])
    #expect(bookingsOnly.metrics.map(\.path) == ["metric_0"])
    #expect(bookingsOnly.query == #"SELECT (SELECT count(*) FROM "public"."bookings") AS metric_0"#)
    #expect(bookingsOnly.autoStats?.relationships == relationships)
}

@Test func selectingHeadlineCountsRejectsStaleAliasesAndCustomQueries() throws {
    var preview = try PostgresConnector.countingConnection(base: analyticsBase(), tables: [analyticsUsers, analyticsBookings])
    #expect(throws: PulseError.self) { try PostgresConnector.selectedCountingConnection(base: preview, metricPaths: []) }
    #expect(throws: PulseError.self) { try PostgresConnector.selectedCountingConnection(base: preview, metricPaths: ["metric_7"]) }
    preview.query += " WHERE true"
    #expect(throws: PulseError.self) { try PostgresConnector.selectedCountingConnection(base: preview, metricPaths: ["metric_0"]) }
    preview = try PostgresConnector.countingConnection(base: analyticsBase(), tables: [analyticsUsers, analyticsBookings])
    preview.metrics.reverse()
    #expect(throws: PulseError.self) { try PostgresConnector.selectedCountingConnection(base: preview, metricPaths: ["metric_0"]) }
}

@Test func legacyCountInferenceNeverRewritesCustomQueries() throws {
    let tables = [analyticsUsers, analyticsBookings]
    var connection = try PostgresConnector.countingConnection(base: analyticsBase(), tables: tables)
    #expect(PostgresConnector.inferredSourceTables(connection: connection, available: tables) == tables)
    #expect(PostgresConnector.inferredSourceTables(connection: connection, available: Array(tables.reversed())) == tables)
    connection.query += " WHERE true"
    #expect(PostgresConnector.inferredSourceTables(connection: connection, available: tables).isEmpty)
    connection.query = "SELECT count(*) AS metric_0 FROM public.users"
    #expect(PostgresConnector.inferredSourceTables(connection: connection, available: tables).isEmpty)
    connection.autoStats = nil
    #expect(try PostgresConnector.queryWithAnalytics(connection) == connection.query)
}

@Test func automaticPlanRejectsUnknownVersionsAndExcessRelationships() throws {
    var base = analyticsBase()
    base.autoStats = DatabaseAnalyticsPlan(relationships: [analyticsRelationship()], version: 2)
    #expect(throws: PulseError.self) { try PostgresConnector.queryWithAnalytics(base) }
    base.autoStats = DatabaseAnalyticsPlan(relationships: [])
    #expect(throws: PulseError.self) { try PostgresConnector.queryWithAnalytics(base) }
}

@Test func automaticPlanNeverUsesSensitiveContactKeysAsRowIdentities() throws {
    for column in ["email", "contact_email", "phoneNumber", "api_key", "access_token", "accountNumber", "street_address"] {
        var relationship = analyticsRelationship(label: nil)
        relationship.parentColumn = column
        var base = analyticsBase()
        base.autoStats = DatabaseAnalyticsPlan(relationships: [relationship])
        #expect(throws: PulseError.self) { try PostgresConnector.queryWithAnalytics(base) }
    }
    var normal = analyticsBase()
    normal.autoStats = DatabaseAnalyticsPlan(relationships: [analyticsRelationship(label: nil)])
    #expect(try PostgresConnector.queryWithAnalytics(normal).contains("left(p.\"id\"::text, 8)"))
}
