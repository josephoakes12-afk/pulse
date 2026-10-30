import Foundation
import Testing
@testable import PulseCore

private func drawerConnection(paths: [String] = ["metrics.users"]) -> ProjectConnection {
    ProjectConnection(name: "Example", endpoint: "https://example.test/summary", metrics: paths.map { MetricDefinition(label: $0 == "metrics.users" ? "Users" : ProjectSetup.friendlyLabel($0.components(separatedBy: ".").last ?? $0), path: $0) })
}

@Test func drawerAutomaticallyFindsUnusedSummaryNumbersWithStableIdentities() throws {
    let connection = drawerConnection()
    let first = try HTTPConnector.snapshot(data: Data(#"{"metrics":{"users":12,"bookings7d":38,"activeUsers":5,"customerID":999},"records":[{"age":32}],"events":[]}"#.utf8), connection: connection)
    let second = try HTTPConnector.snapshot(data: Data(#"{"metrics":{"bookings7d":40,"customerID":999,"activeUsers":6,"users":12},"events":[]}"#.utf8), connection: connection)
    #expect(first.metrics.map(\.value) == ["12"])
    #expect(first.details?.map(\.label) == ["Active Users", "Bookings · 7d"])
    #expect(first.details?.map(\.value) == ["5", "38"])
    #expect(first.details?.map(\.id) == second.details?.map(\.id))
    #expect(second.details?.map(\.value) == ["6", "40"])
    #expect(first.breakdowns == nil)
}

@Test func drawerExplicitDetailsPreferSourceLabelsAndExcludeSelectedPaths() throws {
    let connection = drawerConnection(paths: ["metrics.users", "details.active"])
    let snapshot = try HTTPConnector.snapshot(data: Data(#"{"metrics":{"users":12,"bookings":38,"privateKey":1234},"details":{"active":5,"averageBookings":3.2,"email":1234,"business_id":1234,"flag":true}}"#.utf8), connection: connection)
    #expect(snapshot.details?.map(\.label) == ["Average Bookings", "Bookings"])
    #expect(snapshot.details?.map(\.value) == ["3.2", "38"])
    #expect(!((snapshot.details ?? []).contains { $0.value == "1234" }))
}

@Test func drawerReadsPostgresReservedFieldsAndKeepsZeroCountGroups() throws {
    let connection = drawerConnection(paths: ["metric_0"])
    let payload = Data(#"{"metric_0":38,"__pulse_details":[{"id":"average","label":"Avg / user","value":3.2},{"id":"active","label":"Users with bookings","value":5}],"__pulse_breakdowns":[{"id":"bookings-users","title":"Bookings by user","rows":[{"id":"one","label":"User 1","value":12},{"id":"two","label":"User 2","value":0}],"truncated":false}]}"#.utf8)
    let first = try HTTPConnector.snapshot(data: payload, connection: connection)
    let second = try HTTPConnector.snapshot(data: payload, connection: connection)
    #expect(first.details?.map(\.value) == ["3.2", "5"])
    #expect(first.breakdowns?.first?.title == "Bookings by user")
    #expect(first.breakdowns?.first?.rows.map(\.value) == ["12", "0"])
    #expect(first.breakdowns?.first?.rows.map(\.id) == ["one", "two"])
    #expect(first.details?.map(\.id) == second.details?.map(\.id))
    #expect(first.breakdowns?.map(\.id) == second.breakdowns?.map(\.id))
}

@Test func drawerBoundsDetailsGroupsAndRowsWithoutChangingHeadlines() throws {
    let fields = (0..<40).map { ["id": "detail-\($0)", "label": "Extra \($0)", "value": $0] as [String: Any] }
    let rows = (0..<20).map { ["id": "user-\($0)", "label": "User \($0)", "value": $0] as [String: Any] }
    let groups = (0..<5).map { ["id": "group-\($0)", "title": "Group \($0)", "rows": rows] as [String: Any] }
    let payload = try JSONSerialization.data(withJSONObject: ["metrics": ["users": 20], "details": fields, "breakdowns": groups])
    let snapshot = try HTTPConnector.snapshot(data: payload, connection: drawerConnection())
    #expect(snapshot.metrics.first?.value == "20")
    #expect(snapshot.details?.count == 24)
    #expect(snapshot.breakdowns?.count == 4)
    #expect(snapshot.breakdowns?.allSatisfy { $0.rows.count == 10 && $0.truncated } == true)
}

@Test func malformedOptionalDrawerDataDoesNotBreakAValidHeadline() throws {
    let connection = drawerConnection()
    for optional in [#""details":"invalid","breakdowns":true"#,
                     #""details":[{"label":"Invalid","value":null}],"breakdowns":[{"title":"Missing rows"}]"#,
                     #""details":[{"label":"Wrong type","value":true}],"breakdowns":[{"title":"Bad row","rows":[{"label":"Bad","value":{}}]}]"#] {
        let payload = Data((#"{"metrics":{"users":12},"# + optional + "}").utf8)
        let snapshot = try HTTPConnector.snapshot(data: payload, connection: connection)
        #expect(snapshot.metrics.first?.value == "12")
        #expect(snapshot.details == nil)
        #expect(snapshot.breakdowns == nil)
    }
}

@Test func drawerDeduplicatesExplicitValuesAndDoesNotPromoteItsFieldsToHeadlines() throws {
    let payload = Data(#"{"users":12,"details":[{"id":"users","label":"Users","value":12},{"id":"active","label":"Active","value":5},{"id":"active","label":"Repeated","value":10}],"breakdowns":[{"title":"Bookings by user","rows":[{"id":"one","label":"User 1","value":12}]}],"__pulse_details":{"another":100},"__pulse_breakdowns":[{"title":"Reserved","rows":[{"label":"User 2","value":3}]}]}"#.utf8)
    #expect(try HTTPConnector.discover(data: payload).map(\.path) == ["users"])
    let connection = drawerConnection(paths: ["users"])
    let snapshot = try HTTPConnector.snapshot(data: payload, connection: connection)
    #expect(snapshot.details?.map(\.label) == ["Another"])
    #expect(snapshot.breakdowns?.map(\.title) == ["Reserved"])
}

@Test func drawerDoesNotInferGroupedPeopleFromRawRecordArrays() throws {
    let payload = Data(#"{"metrics":{"users":12},"users":[{"id":"private","name":"Private Person","email":"private@example.test","bookings":10}],"bookings":[{"user_id":"private","value":100}]}"#.utf8)
    let snapshot = try HTTPConnector.snapshot(data: payload, connection: drawerConnection())
    #expect(snapshot.details == nil)
    #expect(snapshot.breakdowns == nil)
}

@Test func drawerDoesNotMergeDistinctPeopleWithTheSameDisplayName() throws {
    let payload = Data(#"{"metrics":{"users":2},"details":[{"id":"metrics.users","label":"All users","value":2},{"id":"active","label":"Active","value":1},{"id":"active","label":"Repeated","value":9}],"breakdowns":[{"title":"Bookings by user","rows":[{"label":"Alex","value":3},{"label":"Alex","value":4}]}]}"#.utf8)
    let snapshot = try HTTPConnector.snapshot(data: payload, connection: drawerConnection())
    #expect(snapshot.details?.map(\.label) == ["Active"])
    #expect(snapshot.breakdowns?.first?.rows.map(\.value) == ["3", "4"])
    #expect(Set(snapshot.breakdowns?.first?.rows.map(\.id) ?? []).count == 2)
}

private actor DrawerRequestCounter {
    var count = 0
    func increment() { count += 1 }
}

@Test func drawerCollectionUsesOnlyTheConfiguredRequest() async throws {
    let counter = DrawerRequestCounter()
    let connector = HTTPConnector(transport: { request in
        await counter.increment()
        #expect(request.url?.absoluteString == "https://example.test/summary")
        return (Data(#"{"metrics":{"users":12,"bookings":38},"breakdowns":[{"title":"Bookings by user","rows":[{"label":"User 1","value":12}]}]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let snapshot = try await connector.collect(connection: drawerConnection(), secret: nil)
    #expect(snapshot.details?.first?.value == "38")
    #expect(snapshot.breakdowns?.first?.rows.first?.value == "12")
    #expect(await counter.count == 1)
}
