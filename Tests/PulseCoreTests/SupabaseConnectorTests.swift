import Foundation
import Testing
@testable import PulseCore

private let supabaseTestRef = "abcdefghijklmnopqrst"
private func supabaseSQLConnection() -> ProjectConnection {
    ProjectConnection(name: "Summary", kind: .supabase, endpoint: "https://api.supabase.com/v1/projects/\(supabaseTestRef)/database/query/read-only", query: "SELECT count(*) AS total FROM public.items", metrics: [MetricDefinition(label: "Items", path: "metrics.items")])
}
private func supabaseRESTConnection(_ metrics: [SupabaseRESTMetric], nowRange: String = "7d") throws -> ProjectConnection {
    ProjectConnection(name: "Counts", kind: .supabase, endpoint: "https://\(supabaseTestRef).supabase.co/rest/v1", query: try SupabaseRESTPlan(defaultRange: nowRange, coverage: "Created records; subscriptions are current status.", metrics: metrics).encodedQuery(), metrics: metrics.map { MetricDefinition(label: $0.key == "paying" ? "Paying now" : ProjectSetup.friendlyLabel($0.key), path: "metrics." + $0.key) })
}
private func supabaseResponse(_ request: URLRequest, status: Int = 200, headers: [String: String]? = nil) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
}

@Test func supabaseRestrictedSQLPostsOnlyToReadOnlyRouteAndUnwrapsOneRow() async throws {
    let connection = supabaseSQLConnection()
    let connector = SupabaseConnector(transport: { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == connection.endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-private-key")
        #expect(request.value(forHTTPHeaderField: "apikey") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: String])
        #expect(body == ["query": connection.query])
        return (Data(#"[{"metrics":{"items":7},"ranges":{"lifetime":{"metrics":{"items":7}}},"coverage":"Actual source"}]"#.utf8), supabaseResponse(request, status: 201))
    })
    let snapshot = try await connector.collect(connection: connection, secret: "test-private-key")
    #expect(snapshot.metrics.first?.value == "7")
    #expect(snapshot.coverage == "Actual source")
    #expect(snapshot.forRange(.lifetime)?.metrics.first?.value == "7")
    #expect(snapshot.forRange(.last24Hours) == nil)
}

@Test func supabaseValidatesRoutesAndReadOnlySQLBeforeSendingCredentials() async throws {
    let connector = SupabaseConnector(transport: { _ in
        Issue.record("Invalid configuration must never send a credential.")
        throw CancellationError()
    })
    for endpoint in [
        "https://api.supabase.com.evil.test/v1/projects/\(supabaseTestRef)/database/query/read-only",
        "https://api.supabase.com/v1/projects/\(supabaseTestRef)/database/query",
        "https://api.supabase.com/v1/projects/\(supabaseTestRef)/database/query/read-only?token=secret",
        "https://user@api.supabase.com/v1/projects/\(supabaseTestRef)/database/query/read-only",
        "http://\(supabaseTestRef).supabase.co/rest/v1",
        "https://\(supabaseTestRef).supabase.co/rest/v1/rpc/mutate",
        "https://\(supabaseTestRef).supabase.co:8443/rest/v1"
    ] {
        var connection = supabaseSQLConnection(); connection.endpoint = endpoint
        await #expect(throws: PulseError.self) { try await connector.collect(connection: connection, secret: "test-private-key") }
    }
    var connection = supabaseSQLConnection()
    for query in ["DELETE FROM public.items", "SELECT 1; SELECT 2", "WITH deleted AS (DELETE FROM public.items RETURNING id) SELECT count(*) FROM deleted", "SELECT pg_notify('x','y')"] {
        connection.query = query
        await #expect(throws: PulseError.self) { try await connector.collect(connection: connection, secret: "test-private-key") }
    }
}

private actor SupabaseCountRecorder {
    var active = 0, maximum = 0
    var urls: [URL] = []
    func start(_ url: URL) { active += 1; maximum = max(maximum, active); urls.append(url) }
    func finish() { active -= 1 }
    func result() -> (Int, [URL]) { (maximum, urls) }
}

@Test func supabaseHEADCountsBuildAllRangesDailyDSTBoundariesAndExplicitCounters() async throws {
    let now = try #require(HTTPConnector.parseDate("2026-10-26T12:00:00Z"))
    let recorder = SupabaseCountRecorder()
    let connection = try supabaseRESTConnection([
        SupabaseRESTMetric(key: "businesses", table: "businesses", select: "id,business_admins!inner(user_id)", filters: [SupabaseRESTFilter(column: "business_admins.role", value: "eq.owner")], timeColumn: "created_at", daily: true, notificationCounter: true, finiteLabel: "New businesses", counterLabel: "Businesses", unitSingular: "business", unitPlural: "businesses"),
        SupabaseRESTMetric(key: "bookings", table: "appointments", filters: [SupabaseRESTFilter(column: "status", value: "in.(confirmed,completed,no_show)")], timeColumn: "created_at", daily: true, notificationCounter: true),
        SupabaseRESTMetric(key: "paying", table: "entitlements", filters: [SupabaseRESTFilter(column: "or", value: "(expires_at.is.null,expires_at.gt.{{now}})")], notificationCounter: true)
    ])
    let connector = SupabaseConnector(transport: { request in
        let url = try #require(request.url)
        await recorder.start(url)
        #expect(request.httpMethod == "HEAD")
        #expect(request.httpBody == nil)
        #expect(url.host == "\(supabaseTestRef).supabase.co")
        #expect(!url.absoluteString.contains("test-private-key"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-private-key")
        #expect(request.value(forHTTPHeaderField: "apikey") == "test-private-key")
        #expect(request.value(forHTTPHeaderField: "Prefer") == "count=exact")
        #expect(request.value(forHTTPHeaderField: "Range") == "0-0")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let lower = items.first { $0.name == "created_at" && $0.value?.hasPrefix("gte.") == true }?.value
        let count: Int
        if url.path.hasSuffix("entitlements") {
            #expect(items.first(where: { $0.name == "or" })?.value == "(expires_at.is.null,expires_at.gt.2026-10-26T12:00:00Z)")
            count = 0
        } else {
            switch lower {
            case nil: count = url.path.hasSuffix("businesses") ? 5 : 100
            case "gte.2026-10-25T12:00:00Z": count = 1
            case "gte.2026-10-19T12:00:00Z": count = 3
            case "gte.2026-09-26T12:00:00Z": count = 4
            case "gte.2026-10-26T00:00:00Z": count = 2
            case "gte.2026-10-24T23:00:00Z":
                // London left daylight saving during yesterday: this calendar day spans 25 hours.
                #expect(items.contains { $0.name == "created_at" && $0.value == "lt.2026-10-26T00:00:00Z" })
                count = 1
            default: Issue.record("Unexpected time window"); count = -1
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        await recorder.finish()
        return (Data(), supabaseResponse(request, headers: ["Content-Range": count == 0 ? "*/0" : "0-0/\(count)"]))
    })
    let snapshot = try await connector.collect(connection: connection, secret: "Bearer test-private-key", now: now)
    #expect(snapshot.metrics.map(\.value) == ["3", "3", "0"])
    #expect(snapshot.metrics.first?.label == "New businesses")
    #expect(snapshot.forRange(.lifetime)?.metrics.map(\.value) == ["5", "100", "0"])
    #expect(snapshot.forRange(.lifetime)?.metrics.first?.label == "Businesses")
    #expect(snapshot.forRange(.last24Hours)?.metrics.map(\.value) == ["1", "1", "0"])
    #expect(snapshot.forRange(.last30Days)?.metrics.map(\.value) == ["4", "4", "0"])
    #expect(snapshot.ranges?.values.allSatisfy { $0.metrics.last?.label == "Paying now" } == true)
    #expect(snapshot.alertObservations?.counters.map(\.value) == [5, 100, 0])
    #expect(snapshot.alertObservations?.counters.first?.unitSingular == "business")
    #expect(snapshot.alertObservations?.daily.map(\.today) == [2, 2])
    #expect(snapshot.alertObservations?.daily.map(\.yesterday) == [1, 1])
    #expect(snapshot.alertObservations?.daily.allSatisfy { $0.day == "2026-10-26" } == true)
    let (maximum, urls) = await recorder.result()
    #expect(urls.count == 13)
    #expect(maximum == 3)
    #expect(urls.filter { $0.path.hasSuffix("entitlements") }.count == 1)
}

@Test func supabaseMissingApproximateOrMalformedCountHeadersNeverBecomeZero() async throws {
    let connection = try supabaseRESTConnection([SupabaseRESTMetric(key: "items", table: "items")])
    for range in [nil, "*/*", "*/-1", "42", "*/9223372036854775808", "0-0/NaN"] as [String?] {
        let connector = SupabaseConnector(transport: { request in
            return (Data(), supabaseResponse(request, headers: range.map { ["Content-Range": $0] }))
        })
        await #expect(throws: PulseError.self) { try await connector.collect(connection: connection, secret: "private-key") }
    }
    let zero = SupabaseConnector(transport: { request in (Data(), supabaseResponse(request, headers: ["Content-Range": "*/0"])) })
    let snapshot = try await zero.collect(connection: connection, secret: "private-key")
    #expect(snapshot.metrics.first?.value == "0")
    #expect(snapshot.alertObservations?.counters.isEmpty != false)
}

@Test func supabaseResponsesErrorsAndCancellationStayBoundedAndPrivate() async throws {
    let connection = supabaseSQLConnection()
    for status in [302, 401, 403, 429, 503] {
        let connector = SupabaseConnector(transport: { request in (Data("provider-private-key-and-person".utf8), supabaseResponse(request, status: status)) })
        do { _ = try await connector.collect(connection: connection, secret: "private-key"); Issue.record("Expected rejection") }
        catch { #expect(!error.localizedDescription.contains("private-key")); #expect(!error.localizedDescription.contains("person")) }
    }
    for body in ["[]", "[{},{}]", "{}", "not-json", String(repeating: "x", count: HTTPConnector.maximumResponseBytes + 1)] {
        let connector = SupabaseConnector(transport: { request in (Data(body.utf8), supabaseResponse(request)) })
        await #expect(throws: PulseError.self) { try await connector.collect(connection: connection, secret: "private-key") }
    }
    let unsafe = SupabaseConnector(transport: { _ in throw PulseError.response("provider-private-key") })
    do { _ = try await unsafe.collect(connection: connection, secret: "private-key"); Issue.record("Expected rejection") }
    catch { #expect(!error.localizedDescription.contains("private-key")) }
    let cancelled = SupabaseConnector(transport: { _ in throw CancellationError() })
    await #expect(throws: CancellationError.self) { try await cancelled.collect(connection: connection, secret: "private-key") }
}

@Test func supabaseCountPlanRejectsRPCPathsInjectedDirectivesAndInvalidMappings() throws {
    for metric in [
        SupabaseRESTMetric(key: "items", table: "rpc/mutate"),
        SupabaseRESTMetric(key: "items", table: "items", select: "id&select=*"),
        SupabaseRESTMetric(key: "items", table: "items", filters: [SupabaseRESTFilter(column: "select", value: "eq.private")]),
        SupabaseRESTMetric(key: "items", table: "items", filters: [SupabaseRESTFilter(column: "status", value: "eq.active\r\nHost:evil")]),
        SupabaseRESTMetric(key: "items", table: "items", daily: true)
    ] {
        let connection = try supabaseRESTConnection([metric])
        #expect(throws: PulseError.self) { try ConnectorValidation.validate(connection) }
    }
    var connection = try supabaseRESTConnection([SupabaseRESTMetric(key: "items", table: "items")])
    connection.metrics[0].path = "metrics.nonexistent"
    #expect(throws: PulseError.self) { try ConnectorValidation.validate(connection) }
    connection = try supabaseRESTConnection([SupabaseRESTMetric(key: "items", table: "items"), SupabaseRESTMetric(key: "items", table: "items")])
    #expect(throws: PulseError.self) { try ConnectorValidation.validate(connection) }
}
