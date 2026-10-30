import Foundation
import Testing
@testable import PulseCore

private func presetData(_ overrides: [String: Any] = [:]) throws -> Data {
    var payload: [String: Any] = [
        "version": 1,
        "name": "Example project",
        "kind": "http",
        "endpoint": "https://example.com/api/summary",
        "metrics": [["label": "Accounts", "path": "metrics.accounts"], ["label": "Bookings · 7d", "path": "metrics.bookings7d"]]
    ]
    payload.merge(overrides) { _, new in new }
    return try JSONSerialization.data(withJSONObject: payload)
}

@Test func projectPresetPreservesPublicSettingsAndCreatesNewIdentities() throws {
    let data = try presetData(["authHeader": "X-API-Key", "symbol": "calendar", "link": "https://example.com/projects"])
    let first = try ProjectPreset.decode(data)
    let second = try ProjectPreset.decode(data)
    #expect(first.name == "Example project")
    #expect(first.kind == .http)
    #expect(first.endpoint == "https://example.com/api/summary")
    #expect(first.authHeader == "X-API-Key")
    #expect(first.symbol == "calendar")
    #expect(first.link == "https://example.com/projects")
    #expect(first.metrics.map(\.label) == ["Accounts", "Bookings · 7d"])
    #expect(first.metrics.map(\.path) == ["metrics.accounts", "metrics.bookings7d"])
    #expect(first.id != second.id)
    #expect(first.credentialVersion != second.credentialVersion)
    #expect(first.metrics.map(\.id) != second.metrics.map(\.id))
    #expect(first.notificationsEnabled == false)
    #expect(first.intervalSeconds == 300)
}

@Test func projectPresetDefaultsAndWhitespaceAreHandled() throws {
    let data = Data(#"{"name":"  My project  ","kind":"http","endpoint":"  http://localhost:8765/summary  ","metrics":[{"label":" Accounts ","path":" metrics.accounts "}]}"#.utf8)
    let connection = try ProjectPreset.decode(data)
    #expect(connection.name == "My project")
    #expect(connection.endpoint == "http://localhost:8765/summary")
    #expect(connection.authHeader == "Authorization")
    #expect(connection.metrics.first?.label == "Accounts")
    #expect(connection.metrics.first?.path == "metrics.accounts")
}

@Test func projectPresetRejectsUnsupportedVersionAndMalformedPayload() throws {
    for version: Any in [2, "1", true, 1.5] {
        #expect(throws: PulseError.self) { try ProjectPreset.decode(presetData(["version": version])) }
    }
    for text in ["not JSON", "[]", "null", #"{"name":"Missing fields"}"#] {
        #expect(throws: PulseError.self) { try ProjectPreset.decode(Data(text.utf8)) }
    }
    #expect(throws: PulseError.self) { try ProjectPreset.decode(presetData(["kind": "shell"])) }
    #expect(throws: PulseError.self) { try ProjectPreset.decode(Data(repeating: 32, count: ProjectPreset.maximumBytes + 1)) }
}

@Test func projectPresetRejectsSecretsAndPrivateExtraSettings() throws {
    for key in ["password", "secret", "token", "api_key", "API-Key", "Authorization", "accessToken"] {
        #expect(throws: PulseError.self) { try ProjectPreset.decode(presetData([key: "must-not-import"])) }
    }
    #expect(throws: PulseError.self) { try ProjectPreset.decode(presetData(["metrics": [["label": "Accounts", "path": "metrics.accounts", "token": "must-not-import"]]])) }
    #expect(throws: PulseError.self) { try ProjectPreset.decode(presetData(["metadata": ["nested": [["password": "must-not-import"]]]])) }
    #expect(throws: PulseError.self) { try ProjectPreset.decode(presetData(["id": UUID().uuidString])) }
    #expect(throws: PulseError.self) { try ProjectPreset.decode(presetData(["credentialVersion": UUID().uuidString])) }
    #expect(throws: PulseError.self) { try ProjectPreset.decode(presetData(["notificationsEnabled": true])) }
    #expect(throws: PulseError.self) { try ProjectPreset.decode(presetData(["query": "SELECT 1 AS total"])) }
}

@Test func projectPresetRetainsConnectorAndLinkSafetyChecks() throws {
    for endpoint in ["https://reader:password@example.com/summary", "https://example.com/summary?access_token=private", "http://example.com/summary"] {
        #expect(throws: PulseError.self) { try ProjectPreset.decode(presetData(["endpoint": endpoint])) }
    }
    for link in ["file:///tmp/project", "javascript:alert(1)", "https://reader:password@example.com/", "https://example.com/?api_key=private"] {
        #expect(throws: PulseError.self) { try ProjectPreset.decode(presetData(["link": link])) }
    }
    #expect(throws: PulseError.self) { try ProjectPreset.decode(presetData(["metrics": []])) }
    #expect(throws: PulseError.self) { try ProjectPreset.decode(presetData(["metrics": (1...4).map { ["label": "Metric \($0)", "path": "metrics.value\($0)"] }])) }
}

@Test func projectPresetAllowsReadOnlyDatabaseTemplateWithoutPassword() throws {
    let connection = try ProjectPreset.decode(presetData([
        "kind": "postgres", "endpoint": "postgresql://pulse_reader@db.example.com/app",
        "query": "SELECT count(*) AS accounts FROM reporting.accounts",
        "metrics": [["label": "Accounts", "path": "accounts"]]
    ]))
    #expect(connection.kind == .postgres)
    #expect(connection.query == "SELECT count(*) AS accounts FROM reporting.accounts")
    #expect(throws: PulseError.self) { try ProjectPreset.decode(presetData([
        "kind": "postgres", "endpoint": "postgresql://pulse_reader:private@db.example.com/app",
        "query": "SELECT count(*) AS accounts FROM reporting.accounts"
    ])) }
    #expect(throws: PulseError.self) { try ProjectPreset.decode(presetData([
        "kind": "postgres", "endpoint": "postgresql://pulse_reader@db.example.com/app",
        "query": "DELETE FROM reporting.accounts"
    ])) }
}
