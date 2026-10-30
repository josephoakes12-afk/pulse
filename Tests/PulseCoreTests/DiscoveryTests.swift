import Foundation
import Testing
@testable import PulseCore

@Test func discoveryPrefersExplicitMetricsAndFindsNestedNumbers() throws {
    let payload = Data(#"{"count":999,"stats":{"ignored":14},"metrics":{"activeUsers":42,"bookings7d":38,"readers":{"signedIn":12}}}"#.utf8)
    let metrics = try HTTPConnector.discover(data: payload)
    #expect(metrics.map(\.path) == ["metrics.activeUsers", "metrics.bookings7d", "metrics.readers.signedIn"])
    #expect(metrics.map(\.previewValue) == ["42", "38", "12"])
    #expect(metrics.first?.label == "Active Users")
    #expect(metrics.last?.label == "Readers Signed In")
    #expect(!metrics.contains { $0.previewValue == "999" })
}

@Test func discoverySkipsIdentifiersMetadataCredentialsAndRecordArrays() throws {
    let payload = Data(#"{"stats":{"activeUsers":5,"business_id":123,"customerID":321,"password":12345,"encryptionKey":555,"email":123,"phoneNumber":1234567,"createdAtMs":1790000000000,"lastSeen":1790000000,"timestamp":1790000000,"enabled":true,"records":[{"count":666}],"events":[{"id":"private","total":777}],"literal.dot":44}}"#.utf8)
    let metrics = try HTTPConnector.discover(data: payload)
    #expect(metrics.map(\.path) == ["stats.activeUsers"])
    #expect(metrics.first?.previewValue == "5")
}

@Test func discoveryAcceptsZeroAndFiniteNumericStrings() throws {
    let payload = Data(#"{"metrics":{"amount":"12.50","empty":0,"scientific":"1.2e3","notFinite":"1e9999","text":"private@example.com","flag":false}}"#.utf8)
    let metrics = try HTTPConnector.discover(data: payload)
    #expect(metrics.map(\.path) == ["metrics.amount", "metrics.empty", "metrics.scientific"])
    #expect(metrics.map(\.previewValue) == ["12.50", "0", "1.2e3"])
}

@Test func discoveryIsStableBoundedAndDoesNotModifySourceData() throws {
    var values: [String: Any] = [:]
    for index in (0..<50).reversed() { values[String(format: "count%02d", index)] = index }
    let payload = try JSONSerialization.data(withJSONObject: ["metrics": values])
    let original = payload
    let first = try HTTPConnector.discover(data: payload)
    let second = try HTTPConnector.discover(data: payload)
    #expect(first == second)
    #expect(first.count == 30)
    #expect(first.first?.path == "metrics.count00")
    #expect(first.last?.path == "metrics.count29")
    #expect(payload == original)
    let deep = Data(#"{"metrics":{"visible":1,"a":{"b":{"c":{"d":{"tooDeep":9}}}}}}"#.utf8)
    #expect(try HTTPConnector.discover(data: deep).map(\.path) == ["metrics.visible"])
}

@Test func discoveryHasActionablePrivateErrorsForUnsupportedPayloads() throws {
    for payload in [#"{"secret":"private-token","enabled":true}"#, #"[{"users":4}]"#, "not JSON"] {
        do { _ = try HTTPConnector.discover(data: Data(payload.utf8)); Issue.record("Expected discovery error") }
        catch {
            #expect(!error.localizedDescription.contains("private-token"))
            #expect(!error.localizedDescription.contains("enabled"))
        }
    }
    #expect(throws: PulseError.self) { try HTTPConnector.discover(data: Data(repeating: 32, count: HTTPConnector.maximumResponseBytes + 1)) }
}

@Test func discoveryUsesSharedAuthenticationWithoutNeedingMetricPaths() async throws {
    let connection = ProjectConnection(name: "Example", endpoint: "https://example.test/summary", authHeader: "X-API-Key", metrics: [])
    let connector = HTTPConnector(transport: { request in
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "test-key")
        #expect(request.timeoutInterval == 15)
        return (Data(#"{"metrics":{"users":8}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let metrics = try await connector.discover(connection: connection, secret: "test-key")
    #expect(metrics.first?.path == "metrics.users")
    #expect(connection.metrics.isEmpty)
    let denied = HTTPConnector(transport: { request in
        (Data("private service body with test-key".utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
    })
    do { _ = try await denied.discover(connection: connection, secret: "test-key"); Issue.record("Expected denied error") }
    catch { #expect(error.localizedDescription.contains("Access denied")); #expect(!error.localizedDescription.contains("test-key")) }
}

private actor DiscoveryRequestCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@Test func instanceDiscoveryValidatesEventAndDateMetadataWithoutFetchingAgain() async throws {
    let connection = ProjectConnection(name: "Example", endpoint: "https://example.test/summary", metrics: [])
    for payload in [#"{"metrics":{"users":8},"events":"private-invalid-event"}"#, #"{"metrics":{"users":8},"measuredAt":"2099-01-01T00:00:00Z"}"#] {
        let counter = DiscoveryRequestCounter()
        let connector = HTTPConnector(transport: { request in
            await counter.increment()
            return (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do { _ = try await connector.discover(connection: connection, secret: nil); Issue.record("Expected invalid metadata to prevent setup success") }
        catch { #expect(!error.localizedDescription.contains("private-invalid-event")) }
        #expect(await counter.count == 1)
        // Pure discovery remains useful for inspecting an already-loaded JSON object.
        #expect(try HTTPConnector.discover(data: Data(payload.utf8)).first?.path == "metrics.users")
    }
}

@Test func setupExtractsDatabasePasswordWithoutPersistableURLCredentials() throws {
    let parsed = try ProjectSetup.parseAddress("postgresql://reader:p%40ss%2Fword@db.example.test:5432/app?sslmode=require")
    #expect(parsed.kind == .postgres)
    #expect(parsed.secret == "p@ss/word")
    #expect(parsed.endpoint == "postgresql://reader@db.example.test:5432/app?sslmode=require")
    #expect(!parsed.endpoint.contains("p%40ss"))
    #expect(parsed.suggestedName == "Db")
}

@Test func setupRejectsUnsafeHTTPAndURLSecrets() throws {
    for address in ["http://example.test/summary", "https://reader:private@example.test/summary", "https://example.test/summary?access_token=private", "file:///tmp/data.json", "not a URL"] {
        #expect(throws: PulseError.self) { try ProjectSetup.parseAddress(address) }
    }
    let local = try ProjectSetup.parseAddress("  http://127.0.0.1:8765/summary  ")
    #expect(local.endpoint == "http://127.0.0.1:8765/summary")
    #expect(local.suggestedName == "Local project")
    #expect(local.secret == nil)
}
