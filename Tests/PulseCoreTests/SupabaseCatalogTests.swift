import Foundation
import Testing
@testable import PulseCore

private let catalogRef = "abcdefghijklmnopqrst"
private func catalogConnection(_ plan: SupabaseRESTPlan) throws -> ProjectConnection {
    ProjectConnection(name: "Catalog", kind: .supabase, endpoint: "https://\(catalogRef).supabase.co/rest/v1", query: try plan.encodedQuery(),
                      metrics: plan.metrics.map { MetricDefinition(label: $0.label ?? ProjectSetup.friendlyLabel($0.key), path: "metrics." + $0.key) })
}
private func catalogResponse(_ request: URLRequest, total: Int, returned: Int? = nil) -> HTTPURLResponse {
    let range = total == 0 ? "*/0" : "0-\(max(0, (returned ?? 1) - 1))/\(total)"
    return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Range": range])!
}
private actor CatalogRequests {
    var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
    func count() -> Int { urls.count }
}

@Test func supabasePlainCreationCountsAutomaticallyGainMatchingAllTimeChoices() throws {
    let filters = [SupabaseRESTFilter(column: "members.role", value: "eq.owner")]
    let plan = SupabaseRESTPlan(metrics: [
        SupabaseRESTMetric(key: "accounts", table: "accounts", select: "id,members!inner()", filters: filters, timeColumn: "created_at", daily: true, notificationCounter: true),
        SupabaseRESTMetric(key: "orders", table: "orders", timeColumn: "registered_at")
    ])
    var connection = try catalogConnection(plan)
    connection.metrics[0].label = "New accounts"
    let enriched = try SupabaseConnector.enrichCountPlan(connection)
    #expect(enriched.metrics == connection.metrics)
    #expect(enriched.endpoint == connection.endpoint)
    #expect(enriched.credentialVersion == connection.credentialVersion)
    let decoded = try JSONDecoder().decode(SupabaseRESTPlan.self, from: Data(enriched.query.utf8))
    #expect(decoded.metrics == plan.metrics)
    #expect(decoded.details?.map(\.key) == ["total_accounts", "total_orders"])
    #expect(decoded.details?.first?.label == "Total accounts")
    #expect(decoded.details?.first?.select == "id,members!inner()")
    #expect(decoded.details?.first?.filters == filters)
    #expect(decoded.details?.allSatisfy { $0.allTime == true && $0.daily == false && $0.notificationCounter == false } == true)
    #expect(try SupabaseConnector.enrichCountPlan(enriched) == enriched)
}

@Test func supabaseCuratedAndNonCreationCountPlansStayAuthoritative() throws {
    let curated = try catalogConnection(SupabaseRESTPlan(metrics: [SupabaseRESTMetric(key: "items", table: "items", timeColumn: "created_at")], details: [SupabaseRESTMetric(key: "active", table: "items", label: "Active")]))
    #expect(try SupabaseConnector.enrichCountPlan(curated) == curated)
    let status = try catalogConnection(SupabaseRESTPlan(metrics: [SupabaseRESTMetric(key: "items", table: "items", timeColumn: "updated_at")]))
    #expect(try SupabaseConnector.enrichCountPlan(status) == status)
    let fixed = try catalogConnection(SupabaseRESTPlan(metrics: [SupabaseRESTMetric(key: "items", table: "items", timeColumn: "created_at", allTime: true)]))
    #expect(try SupabaseConnector.enrichCountPlan(fixed) == fixed)
}

@Test func supabasePrimaryCountEquivalenceOnlyIgnoresTheOptionalCatalog() throws {
    let previous = try catalogConnection(SupabaseRESTPlan(metrics: [SupabaseRESTMetric(key: "items", table: "items", timeColumn: "created_at", notificationCounter: true)]))
    let enriched = try SupabaseConnector.enrichCountPlan(previous)
    #expect(SupabaseConnector.hasSamePrimaryCountPlan(previous, enriched))
    #expect(SupabaseConnector.hasSamePrimaryCountPlan(previous, previous))
    var changed = enriched
    var plan = try JSONDecoder().decode(SupabaseRESTPlan.self, from: Data(changed.query.utf8))
    plan.metrics[0].filters = [SupabaseRESTFilter(column: "status", value: "eq.active")]
    changed.query = try plan.encodedQuery()
    #expect(!SupabaseConnector.hasSamePrimaryCountPlan(previous, changed))
    changed = enriched; changed.metrics[0].label = "Different meaning"
    #expect(!SupabaseConnector.hasSamePrimaryCountPlan(previous, changed))
    changed = enriched; changed.metrics[0].id = UUID()
    #expect(!SupabaseConnector.hasSamePrimaryCountPlan(previous, changed))
    changed = previous; changed.endpoint = "https://api.supabase.com/v1/projects/\(catalogRef)/database/query/read-only"
    #expect(!SupabaseConnector.hasSamePrimaryCountPlan(changed, changed))
}

@Test func supabaseCatalogUsesScopedCountsForRatiosAndDeduplicatesLifetimeRequests() async throws {
    let accepted = [SupabaseRESTFilter(column: "status", value: "in.(confirmed,completed)")]
    let plan = SupabaseRESTPlan(metrics: [
        SupabaseRESTMetric(key: "bookings", table: "appointments", filters: accepted, timeColumn: "created_at", notificationCounter: true)
    ], details: [
        SupabaseRESTMetric(key: "total_businesses", table: "businesses", timeColumn: "created_at", label: "Total businesses", allTime: true),
        SupabaseRESTMetric(key: "owned_bookings", table: "appointments", select: "id,businesses!inner()", filters: accepted, timeColumn: "created_at", label: "Current business bookings"),
        SupabaseRESTMetric(key: "total_bookings", table: "appointments", filters: accepted, timeColumn: "created_at", label: "Total bookings", allTime: true)
    ], ratios: [
        SupabaseRESTRatio(key: "average", label: "Bookings / business", numerator: "owned_bookings", denominator: "total_businesses"),
        SupabaseRESTRatio(key: "current_share", label: "Current business share %", numerator: "owned_bookings", denominator: "total_bookings", numeratorRange: "lifetime", multiplier: 100)
    ])
    let connection = try catalogConnection(plan)
    let requests = CatalogRequests()
    let now = Date(timeIntervalSince1970: 1_798_747_200)
    let connector = SupabaseConnector(transport: { request in
        let url = try #require(request.url)
        await requests.record(url)
        #expect(request.httpMethod == "HEAD")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let finite = items.contains { $0.name == "created_at" }
        let own = items.first { $0.name == "select" }?.value?.contains("businesses!inner") == true
        let total = url.path.hasSuffix("businesses") ? 5 : own ? (finite ? 4 : 80) : (finite ? 8 : 100)
        return (Data(), catalogResponse(request, total: total))
    })
    let snapshot = try await connector.collect(connection: connection, secret: "private-test-token", now: now)
    #expect(snapshot.metrics.map(\.value) == ["8"])
    #expect(snapshot.details?.first { $0.label == "Total businesses" }?.value == "5")
    #expect(snapshot.details?.first { $0.label == "Total bookings" }?.value == "100")
    #expect(snapshot.details?.first { $0.label == "Bookings / business" }?.value == "0.8")
    #expect(snapshot.forRange(.lifetime)?.details?.first { $0.label == "Bookings / business" }?.value == "16")
    #expect(snapshot.details?.first { $0.label == "Current business share %" }?.value == "80")
    #expect(snapshot.details?.map(\.id) == snapshot.forRange(.lifetime)?.details?.map(\.id))
    #expect(snapshot.alertObservations?.counters.map(\.value) == [100])
    #expect(await requests.count() == 9)
}

@Test func supabaseCatalogDoesNotTurnZeroDenominatorsIntoInventedRates() async throws {
    let plan = SupabaseRESTPlan(metrics: [SupabaseRESTMetric(key: "items", table: "items")], details: [SupabaseRESTMetric(key: "parents", table: "parents", label: "Total parents")], ratios: [SupabaseRESTRatio(key: "average", label: "Items / parent", numerator: "items", denominator: "parents")])
    let connection = try catalogConnection(plan)
    let connector = SupabaseConnector(transport: { request in (Data(), catalogResponse(request, total: 0)) })
    let snapshot = try await connector.collect(connection: connection, secret: "private-test-token")
    #expect(snapshot.details?.first { $0.label == "Items / parent" }?.value == "—")
    #expect(snapshot.details?.first { $0.label == "Total parents" }?.value == "0")
}

@Test func supabaseGroupedCountsOnlyRequestParentLabelsAndCountsAndKeepZeroParents() async throws {
    let group = SupabaseRESTBreakdown(key: "business_bookings", title: "Bookings by business", table: "businesses", parentLabel: "name", childRelation: "appointments", childTimeColumn: "created_at",
                                     childFilters: [SupabaseRESTFilter(column: "status", value: "in.(confirmed,completed)")],
                                     parentFilters: [SupabaseRESTFilter(column: "business_admins.role", value: "eq.owner")], parentJoins: ["business_admins!inner"])
    let connection = try catalogConnection(SupabaseRESTPlan(metrics: [SupabaseRESTMetric(key: "bookings", table: "appointments")], breakdowns: [group]))
    let requests = CatalogRequests()
    let connector = SupabaseConnector(transport: { request in
        let url = try #require(request.url)
        await requests.record(url)
        if request.httpMethod == "HEAD" { return (Data(), catalogResponse(request, total: 6)) }
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Range") == "0-99")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.first { $0.name == "select" }?.value == "id,name,pulse_count:appointments(count),business_admins!inner()")
        #expect(items.first { $0.name == "business_admins.role" }?.value == "eq.owner")
        #expect(items.first { $0.name == "pulse_count.status" }?.value == "in.(confirmed,completed)")
        #expect(items.filter { $0.name == "pulse_count.created_at" }.count == 0 || items.filter { $0.name == "pulse_count.created_at" }.count == 2)
        let rows: [[String: Any]] = [
            ["id": -1, "name": "Oak", "pulse_count": [["count": 4]], "private_note": "must-not-leave-provider"],
            ["id": "two", "name": "Birch", "pulse_count": ["count": 0]],
            ["id": "three", "name": "Elm", "pulse_count": [["count": 2]]]
        ]
        return (try JSONSerialization.data(withJSONObject: rows), catalogResponse(request, total: 3, returned: 3))
    })
    let snapshot = try await connector.collect(connection: connection, secret: "private-test-token")
    #expect(snapshot.breakdowns?.first?.rows.map(\.label) == ["Oak", "Elm", "Birch"])
    #expect(snapshot.breakdowns?.first?.rows.map(\.value) == ["4", "2", "0"])
    #expect(snapshot.breakdowns?.first?.truncated == false)
    #expect(snapshot.breakdowns?.first?.id == snapshot.forRange(.lifetime)?.breakdowns?.first?.id)
    #expect(await requests.count() == 5)
    #expect(!String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("must-not-leave-provider"))
}

@Test func supabaseGroupedListsOverTheBoundAreOmittedWithoutInventingATopList() async throws {
    let group = SupabaseRESTBreakdown(key: "items", title: "Items by project", table: "projects", childRelation: "items")
    let connection = try catalogConnection(SupabaseRESTPlan(coverage: "Exact totals.", metrics: [SupabaseRESTMetric(key: "items", table: "items")], breakdowns: [group]))
    let connector = SupabaseConnector(transport: { request in
        (Data("[]".utf8), catalogResponse(request, total: request.httpMethod == "HEAD" ? 500 : 101, returned: 100))
    })
    let snapshot = try await connector.collect(connection: connection, secret: "private-test-token")
    #expect(snapshot.metrics.first?.value == "500")
    #expect(snapshot.breakdowns == nil)
    #expect(snapshot.coverage?.contains("above 100 items are omitted") == true)
}

@Test func supabaseCatalogRejectsUnknownRatiosAndUnsafeGroupingSelectorsBeforeAuth() async throws {
    let base = SupabaseRESTPlan(metrics: [SupabaseRESTMetric(key: "items", table: "items")])
    var plans: [SupabaseRESTPlan] = []
    var unknown = base; unknown.ratios = [SupabaseRESTRatio(key: "average", label: "Average", numerator: "missing", denominator: "items")]; plans.append(unknown)
    var duplicate = base; duplicate.details = [SupabaseRESTMetric(key: "items", table: "items")]; plans.append(duplicate)
    for group in [
        SupabaseRESTBreakdown(key: "x", title: "Counts", table: "projects", parentLabel: "email", childRelation: "items"),
        SupabaseRESTBreakdown(key: "x", title: "Counts", table: "projects", childRelation: "items(*)"),
        SupabaseRESTBreakdown(key: "x", title: "Counts", table: "projects", childRelation: "items!inner"),
        SupabaseRESTBreakdown(key: "x", title: "Counts", table: "projects", childRelation: "items", parentJoins: ["admins!inner(user_id)"])
    ] { var plan = base; plan.breakdowns = [group]; plans.append(plan) }
    let connector = SupabaseConnector(transport: { _ in Issue.record("Invalid selectors must not send credentials."); throw CancellationError() })
    for plan in plans {
        let connection = try catalogConnection(plan)
        await #expect(throws: PulseError.self) { try await connector.collect(connection: connection, secret: "private-test-token") }
    }
}

@Test func supabaseMalformedGroupedCountsAreNeverShownAsZero() async throws {
    let group = SupabaseRESTBreakdown(key: "items", title: "Items by project", table: "projects", childRelation: "items")
    let connection = try catalogConnection(SupabaseRESTPlan(metrics: [SupabaseRESTMetric(key: "items", table: "items")], breakdowns: [group]))
    for body in [#"[{"id":"p","pulse_count":[{"count":true}]}]"#, #"[{"id":"p","pulse_count":[{"count":-1}]}]"#, #"[{"id":"p","pulse_count":[]}]"#, "[]"] {
        let connector = SupabaseConnector(transport: { request in
            (Data(body.utf8), catalogResponse(request, total: 1))
        })
        await #expect(throws: PulseError.self) { try await connector.collect(connection: connection, secret: "private-test-token") }
    }
}

private actor CatalogSQLRequests {
    var queries: [String] = []
    func record(_ query: String) { queries.append(query) }
    func count() -> Int { queries.count }
}
private func catalogSQLConnection() -> ProjectConnection {
    let parent = DatabaseTable(schema: "public", name: "projects", isView: false)
    let child = DatabaseTable(schema: "public", name: "items", isView: false)
    var connection = ProjectConnection(name: "SQL catalog", kind: .supabase,
                                       endpoint: "https://api.supabase.com/v1/projects/\(catalogRef)/database/query/read-only",
                                       query: "SELECT count(*) AS items FROM public.items", metrics: [MetricDefinition(label: "Items", path: "items")])
    connection.autoStats = DatabaseAnalyticsPlan(relationships: [DatabaseRelationship(child: child, childColumn: "project_id", parent: parent, parentColumn: "id")])
    return connection
}

@Test func supabaseOptionalSQLAnalyticsCanFallBackWithoutChangingTheSavedSummary() async throws {
    let connection = catalogSQLConnection()
    let recorder = CatalogSQLRequests()
    let connector = SupabaseConnector(transport: { request in
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        let query = try #require(body["query"])
        await recorder.record(query)
        if query != connection.query {
            #expect(query.contains("__pulse_details"))
            return (Data("private provider error".utf8), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        }
        return (Data(#"[{"items":9,"coverage":"Saved scope."}]"#.utf8), catalogResponse(request, total: 1))
    })
    let snapshot = try await connector.collect(connection: connection, secret: "private-test-token")
    #expect(snapshot.metrics.first?.value == "9")
    #expect(snapshot.metrics.first?.id == connection.metrics.first?.id)
    #expect(snapshot.coverage?.contains("automatic stats are unavailable") == true)
    #expect(snapshot.coverage?.contains("Saved scope") == true)
    #expect(await recorder.count() == 2)
}

@Test func supabaseOptionalSQLAnalyticsNeverRetriesAuthenticationOrRateLimits() async throws {
    let connection = catalogSQLConnection()
    for status in [401, 403, 429] {
        let recorder = CatalogSQLRequests()
        let connector = SupabaseConnector(transport: { request in
            await recorder.record("request")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: PulseError.self) { try await connector.collect(connection: connection, secret: "private-test-token") }
        #expect(await recorder.count() == 1)
    }
}

@Test func supabaseReadOnlyMetadataIsBoundedAndCannotUseTheWriteCapableRoute() async throws {
    var connection = catalogSQLConnection()
    let connector = SupabaseConnector(transport: { request in
        #expect(request.url?.path.hasSuffix("/database/query/read-only") == true)
        #expect(request.httpMethod == "POST")
        let rows = (0..<101).map { ["column": String($0)] }
        return (try JSONSerialization.data(withJSONObject: rows), catalogResponse(request, total: 101))
    })
    await #expect(throws: PulseError.self) { try await connector.readOnlyRows(connection: connection, secret: "private-test-token", query: "SELECT name FROM pg_catalog.pg_class") }
    connection.endpoint = "https://api.supabase.com/v1/projects/\(catalogRef)/database/query"
    await #expect(throws: PulseError.self) { try await connector.readOnlyRows(connection: connection, secret: "private-test-token", query: "SELECT 1") }
}
