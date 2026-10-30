import Foundation
import Testing
@testable import PulseCore

private func sampleConnection() -> ProjectConnection {
    ProjectConnection(name: "Test project", endpoint: "https://example.test/summary", metrics: [MetricDefinition(label: "Readers · 7d", path: "stats.readers"), MetricDefinition(label: "Signed in", path: "series.0.count")])
}

@Test func nestedJSONMappingRetainsMeasurementAndCoverage() throws {
    let connection = sampleConnection()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let data = Data(#"{"stats":{"readers":42},"series":[{"count":12}],"measuredAt":"2026-10-29T10:30:00Z","coverage":"Consenting readers"}"#.utf8)
    let snapshot = try HTTPConnector.snapshot(data: data, connection: connection, now: now)
    #expect(snapshot.metrics.map(\.value) == ["42", "12"])
    #expect(snapshot.metrics.map(\.id) == connection.metrics.map(\.id))
    #expect(snapshot.coverage == "Consenting readers")
    #expect(snapshot.measuredAt < snapshot.fetchedAt)
    #expect(snapshot.fetchedAt == now)
}

@Test func missingAndNullMetricsNeverBecomeZero() throws {
    let connection = sampleConnection()
    #expect(throws: PulseError.self) { try HTTPConnector.snapshot(data: Data(#"{"stats":{},"series":[{"count":0}]}"#.utf8), connection: connection) }
    #expect(throws: PulseError.self) { try HTTPConnector.snapshot(data: Data(#"{"stats":{"readers":null},"series":[{"count":0}]}"#.utf8), connection: connection) }
    let validZero = try HTTPConnector.snapshot(data: Data(#"{"stats":{"readers":0},"series":[{"count":false}]}"#.utf8), connection: connection)
    #expect(validZero.metrics.map(\.value) == ["0", "No"])
}

@Test func eventsRequireStableIDsAndAreDeduplicated() throws {
    var connection = sampleConnection()
    connection.metrics = [MetricDefinition(label: "Businesses", path: "businesses")]
    let data = Data(#"{"businesses":3,"events":[{"id":"signup:1","title":"New business","occurredAt":"2026-10-29T10:30:00.000Z","url":"javascript:alert(1)"},{"id":"signup:1","title":"New business","occurredAt":"2026-10-29T10:30:00Z"}]}"#.utf8)
    let snapshot = try HTTPConnector.snapshot(data: data, connection: connection, now: Date(timeIntervalSince1970: 1_800_000_000))
    #expect(snapshot.events.count == 1)
    #expect(snapshot.events.first?.url == nil)
    let invalid = Data(#"{"businesses":3,"events":[{"title":"No event ID","occurredAt":"2026-10-29T10:30:00Z"}]}"#.utf8)
    #expect(throws: PulseError.self) { try HTTPConnector.snapshot(data: invalid, connection: connection) }
}

@Test func HTTPUsesCredentialHeaderAndHandlesDeniedAccess() async throws {
    let connection = sampleConnection()
    let connector = HTTPConnector(transport: { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-value")
        #expect(request.httpMethod == "GET")
        return (Data("a private provider error secret-value".utf8), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
    })
    do {
        _ = try await connector.collect(connection: connection, secret: "Bearer secret-value")
        Issue.record("Access denied should fail.")
    } catch {
        #expect(error.localizedDescription.contains("Access denied"))
        #expect(!error.localizedDescription.contains("secret-value"))
        #expect(!error.localizedDescription.contains("private provider"))
    }
}

@Test func HTTPTransportErrorsAreSanitized() async throws {
    let unsafe = HTTPConnector(transport: { _ in throw NSError(domain: "secret.example", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bearer private-token"]) })
    do { _ = try await unsafe.collect(connection: sampleConnection(), secret: nil); Issue.record("Expected error") }
    catch { #expect(!error.localizedDescription.contains("private-token")) }
}

@Test func postgresSummaryAcceptsNativeJSONEventsAndSnakeCaseDates() throws {
    var connection = sampleConnection()
    connection.metrics = [MetricDefinition(label: "Businesses", path: "businesses")]
    let data = Data(#"{"businesses":7,"measured_at":"2026-10-29T10:30:00Z","coverage":"All verified businesses","events":[{"id":"signup:stable-id","title":"New business","occurred_at":"2026-10-29T10:20:00Z"}]}"#.utf8)
    let snapshot = try HTTPConnector.snapshot(data: data, connection: connection, now: Date(timeIntervalSince1970: 1_800_000_000))
    #expect(snapshot.metrics.first?.value == "7")
    #expect(snapshot.events.first?.id == "signup:stable-id")
    #expect(snapshot.measuredAt == HTTPConnector.parseDate("2026-10-29T10:30:00Z"))
}

@Test func endpointValidationProtectsSecretsAndTransport() throws {
    var connection = sampleConnection()
    connection.endpoint = "http://example.test/summary"
    #expect(throws: PulseError.self) { try ConnectorValidation.validate(connection) }
    connection.endpoint = "http://127.0.0.1:8338/summary"
    try ConnectorValidation.validate(connection)
    connection.endpoint = "https://user:password@example.test/summary"
    #expect(throws: PulseError.self) { try ConnectorValidation.validate(connection) }
    connection.endpoint = "https://example.test/summary?access_token=private-token"
    #expect(throws: PulseError.self) { try ConnectorValidation.validate(connection) }
    connection.endpoint = "https://example.test/summary"
    connection.authHeader = "Host"
    #expect(throws: PulseError.self) { try ConnectorValidation.validate(connection) }
    connection.authHeader = "X-API-Key\r\nHost"
    #expect(throws: PulseError.self) { try ConnectorValidation.validate(connection) }
}

@Test func oversizeAndFutureDatedResponsesFail() throws {
    let connection = sampleConnection()
    #expect(throws: PulseError.self) { try HTTPConnector.snapshot(data: Data(repeating: 32, count: HTTPConnector.maximumResponseBytes + 1), connection: connection) }
    let data = Data(#"{"stats":{"readers":42},"series":[{"count":12}],"measuredAt":"2099-10-29T10:30:00Z"}"#.utf8)
    #expect(throws: PulseError.self) { try HTTPConnector.snapshot(data: data, connection: connection) }
}

@Test func PostgreSQLRejectsMutationAndMultipleStatements() throws {
    try ConnectorValidation.validatePostgresQuery("SELECT count(*) AS readers FROM public.reader_summary")
    try ConnectorValidation.validatePostgresQuery("WITH recent AS (SELECT count(*) AS total FROM events) SELECT total FROM recent")
    for query in ["SELECT 1; DROP TABLE users", "DELETE FROM users", "WITH gone AS (DELETE FROM users RETURNING id) SELECT count(*) FROM gone", "SELECT * INTO copy FROM users", "SELECT 1 -- comment", "SELECT pg_sleep(1); COMMIT"] {
        #expect(throws: PulseError.self) { try ConnectorValidation.validatePostgresQuery(query) }
    }
    for query in ["SELECT nextval('account_sequence')", "SELECT set_config('transaction_read_only', 'off', true)", "SELECT pg_notify('alerts', 'test')", "SELECT pg_catalog.pg_sleep(30)", "SELECT dblink_exec('remote', 'DELETE FROM users')"] {
        #expect(throws: PulseError.self) { try ConnectorValidation.validatePostgresQuery(query) }
    }
}

@Test func PostgreSQLRequiresPasswordOutsideURLAndSecureRemoteTLS() throws {
    var connection = ProjectConnection(name: "Database", kind: .postgres, endpoint: "postgresql://reader@db.example.test:5432/app", query: "SELECT 1 AS total", metrics: [MetricDefinition(label: "Total", path: "total")])
    try ConnectorValidation.validate(connection)
    connection.endpoint = "postgresql://reader:secret@db.example.test:5432/app"
    #expect(throws: PulseError.self) { try ConnectorValidation.validate(connection) }
    connection.endpoint = "postgresql://reader@db.example.test:5432/app?sslmode=disable"
    #expect(throws: PulseError.self) { try ConnectorValidation.validate(connection) }
    connection.endpoint = "postgresql://reader@localhost:5432/app?sslmode=disable"
    try ConnectorValidation.validate(connection)
}
