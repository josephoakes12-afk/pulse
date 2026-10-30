import Foundation
import Testing
@testable import PulseCore

private func discoveryDatabase() -> ProjectConnection {
    ProjectConnection(name: "Database", kind: .postgres, endpoint: "postgresql://pulse_reader@db.example.test/app")
}

@Test func generatedCountsUseOneAggregateRowAndHonestLabels() throws {
    let base = discoveryDatabase()
    let tables = [DatabaseTable(schema: "public", name: "users", isView: false), DatabaseTable(schema: "reporting", name: "active_bookings", isView: true)]
    let result = try PostgresConnector.countingConnection(base: base, tables: tables)
    #expect(result.id == base.id)
    #expect(result.endpoint == base.endpoint)
    #expect(result.query == #"SELECT (SELECT count(*) FROM "public"."users") AS metric_0, (SELECT count(*) FROM "reporting"."active_bookings") AS metric_1"#)
    #expect(result.metrics.map(\.path) == ["metric_0", "metric_1"])
    #expect(result.metrics.map(\.label) == ["Users records", "Active bookings records"])
    try ConnectorValidation.validate(result)
}

@Test func generatedCountsQuoteServerIdentifiersRatherThanInterpolatingSQL() throws {
    let tables = [DatabaseTable(schema: "Sales Team", name: "say\"hello", isView: true)]
    let result = try PostgresConnector.countingConnection(base: discoveryDatabase(), tables: tables)
    #expect(result.query == #"SELECT (SELECT count(*) FROM "Sales Team"."say""hello") AS metric_0"#)
    let malicious = [DatabaseTable(schema: "public", name: "users\"); DROP TABLE users; --", isView: false)]
    #expect(throws: PulseError.self) { try PostgresConnector.countingConnection(base: discoveryDatabase(), tables: malicious) }
}

@Test func generatedCountsRejectEmptyDuplicateAndExcessSelections() throws {
    let table = DatabaseTable(schema: "public", name: "users", isView: false)
    #expect(throws: PulseError.self) { try PostgresConnector.countingConnection(base: discoveryDatabase(), tables: []) }
    #expect(throws: PulseError.self) { try PostgresConnector.countingConnection(base: discoveryDatabase(), tables: [table, table]) }
    let four = (0..<4).map { DatabaseTable(schema: "public", name: "table_\($0)", isView: false) }
    #expect(throws: PulseError.self) { try PostgresConnector.countingConnection(base: discoveryDatabase(), tables: four) }
    let invalid = [DatabaseTable(schema: "", name: "users", isView: false)]
    #expect(throws: PulseError.self) { try PostgresConnector.countingConnection(base: discoveryDatabase(), tables: invalid) }
    var wrongKind = discoveryDatabase()
    wrongKind.kind = .http
    #expect(throws: PulseError.self) { try PostgresConnector.countingConnection(base: wrongKind, tables: [table]) }
}

@Test func generatedCountLabelsStayWithinWidgetLimit() throws {
    let table = DatabaseTable(schema: "public", name: String(repeating: "a", count: 63), isView: false)
    let result = try PostgresConnector.countingConnection(base: discoveryDatabase(), tables: [table])
    #expect(result.metrics[0].label.count == 40)
    #expect(result.metrics[0].label.hasSuffix(" records"))
    try ConnectorValidation.validate(result)
}

@Test func generatedCountsQualifyMatchingTableNamesAcrossSchemas() throws {
    let tables = [DatabaseTable(schema: "public", name: "users", isView: false), DatabaseTable(schema: "reporting", name: "users", isView: true)]
    let result = try PostgresConnector.countingConnection(base: discoveryDatabase(), tables: tables)
    #expect(result.metrics.map(\.label) == ["Public · Users records", "Reporting · Users records"])
    #expect(result.metrics.map(\.path) == ["metric_0", "metric_1"])
    #expect(result.query.contains(#"FROM "public"."users""#))
    #expect(result.query.contains(#"FROM "reporting"."users""#))
}

@Test func generatedCountsKeepLongQualifiedLabelsDistinct() throws {
    let prefix = String(repeating: "a", count: 40)
    let tables = [DatabaseTable(schema: prefix + "one", name: "users", isView: false), DatabaseTable(schema: prefix + "two", name: "users", isView: false), DatabaseTable(schema: prefix + "three", name: "users", isView: false)]
    let result = try PostgresConnector.countingConnection(base: discoveryDatabase(), tables: tables)
    #expect(Set(result.metrics.map(\.label)).count == 3)
    #expect(result.metrics.allSatisfy { $0.label.count <= 40 && $0.label.hasSuffix(" records") })
}
