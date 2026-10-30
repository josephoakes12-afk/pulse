import Foundation
import Testing
@testable import PulseCore

private func rangeConnection() -> ProjectConnection {
    ProjectConnection(name: "Example", endpoint: "https://example.invalid/summary",
                      metrics: [MetricDefinition(label: "Accounts", path: "metrics.accounts"), MetricDefinition(label: "Bookings", path: "metrics.bookings")], notificationsEnabled: true)
}

@Test func declaredRangesApplyLabelsAndPreserveIndependentAlertMetadata() throws {
    let payload = Data(#"{"metrics":{"accounts":100,"bookings":200},"ranges":{"24h":{"metrics":{"accounts":2,"bookings":14},"labels":{"metrics.accounts":"New accounts","metrics.bookings":"New bookings"},"coverage":"Last 24 hours","details":[{"id":"active","label":"Active accounts","value":3}],"breakdowns":[{"title":"Bookings by business","rows":[{"label":"Example","value":14}]}]},"7d":{"metrics":{"accounts":8,"bookings":40}},"30d":{"metrics":{"accounts":20,"bookings":90}},"lifetime":{"metrics":{"accounts":100,"bookings":200}},"invented":{"metrics":{"accounts":999}}},"alerts":{"counters":[{"id":"accounts","label":"Accounts","value":100,"unitSingular":"account","unitPlural":"accounts"}],"daily":[{"id":"bookings","label":"Bookings","today":14,"yesterday":12,"day":"2026-10-30"}]}}"#.utf8)
    let snapshot = try HTTPConnector.snapshot(data: payload, connection: rangeConnection())
    #expect(snapshot.ranges?.count == 4)
    let day = try #require(snapshot.forRange(.last24Hours))
    #expect(day.metrics.map(\.value) == ["2", "14"])
    #expect(day.metrics.map(\.label) == ["New accounts", "New bookings"])
    #expect(day.details?.first?.value == "3")
    #expect(day.breakdowns?.first?.rows.first?.value == "14")
    #expect(day.coverage == "Last 24 hours")
    #expect(day.alertObservations == snapshot.alertObservations)
    #expect(day.forRange(.lifetime)?.metrics.map(\.value) == ["100", "200"])
    #expect(snapshot.alertObservations?.counters.first?.value == 100)
    #expect(snapshot.alertObservations?.daily.first?.day == "2026-10-30")
    #expect(try JSONDecoder().decode(ProjectSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
}

@Test func explicitRetainedWindowsNeverPretendToBeLifetimeAndLegacyTotalsRemainAvailable() throws {
    let connection = rangeConnection()
    let retained = try HTTPConnector.snapshot(data: Data(#"{"metrics":{"accounts":8,"bookings":40},"ranges":{"24h":{"metrics":{"accounts":2,"bookings":14}},"7d":{"metrics":{"accounts":8,"bookings":40}}}}"#.utf8), connection: connection)
    #expect(retained.forRange(.lifetime) == nil)
    #expect(retained.forRange(.last30Days) == nil)
    #expect(retained.forRange(.last24Hours)?.forRange(.lifetime) == nil)
    #expect(retained.forRange(.last24Hours)?.forRange(.last7Days)?.metrics.map(\.value) == ["8", "40"])
    let legacy = try HTTPConnector.snapshot(data: Data(#"{"metrics":{"accounts":100,"bookings":200}}"#.utf8), connection: connection)
    #expect(legacy.forRange(.lifetime)?.metrics == legacy.metrics)
    #expect(legacy.forRange(.last24Hours) == nil)
    #expect(legacy.forRange(.last7Days) == nil)
    #expect(legacy.ranges == nil)
    #expect(legacy.alertObservations == nil)
}

@Test func malformedOptionalRangesAndAlertsCannotBreakHeadlinesOrBecomeDiscoverableCounts() throws {
    let connection = rangeConnection()
    let payload = Data(#"{"metrics":{"accounts":100,"bookings":200},"ranges":{"24h":{"metrics":{"accounts":2}},"7d":{"metrics":{"accounts":8,"bookings":40}},"lifetime":false},"alerts":{"counters":[{"id":"negative","label":"Bad","value":-1},{"id":"boolean","label":"Bad","value":true},{"id":"fraction","label":"Bad","value":1.5},{"id":"valid","label":"Valid accounts","value":10}],"daily":[{"id":"bad-day","label":"Bad","today":4,"yesterday":2,"day":"2026-02-30"},{"id":"bad-count","label":"Bad","today":true,"yesterday":2,"day":"2026-10-30"}]}}"#.utf8)
    let snapshot = try HTTPConnector.snapshot(data: payload, connection: connection)
    #expect(snapshot.metrics.map(\.value) == ["100", "200"])
    #expect(snapshot.ranges?.keys.sorted() == ["7d"])
    #expect(snapshot.forRange(.lifetime) == nil)
    #expect(snapshot.alertObservations?.counters.map(\.id) == ["valid"])
    #expect(snapshot.alertObservations?.daily.isEmpty == true)
    #expect(snapshot.details == nil)
    #expect(try HTTPConnector.discover(data: payload).map(\.path) == ["metrics.accounts", "metrics.bookings"])
    let malformed = try HTTPConnector.snapshot(data: Data(#"{"metrics":{"accounts":100,"bookings":200},"ranges":"bad","alerts":false}"#.utf8), connection: connection)
    #expect(malformed.forRange(.lifetime) == nil)
    #expect(malformed.alertObservations == nil)
}

@Test func alertObservationParsingIsBoundedDeduplicatedAndDoesNotReadNestedVariantAlerts() throws {
    let counters: [[String: Any]] = (0..<30).map { ["id": "counter-\($0)", "label": "Accounts", "value": $0] }
    let payload: [String: Any] = ["metrics": ["accounts": 100, "bookings": 200], "alerts": ["counters": counters],
                                 "ranges": ["24h": ["metrics": ["accounts": 1, "bookings": 2], "alerts": ["counters": [["id": "nested", "label": "Must stay ignored", "value": 999]]]]]]
    let parsed = try HTTPConnector.snapshot(data: JSONSerialization.data(withJSONObject: payload), connection: rangeConnection())
    #expect(parsed.alertObservations?.counters.count == 12)
    #expect(parsed.forRange(.last24Hours)?.alertObservations == parsed.alertObservations)
    #expect(parsed.alertObservations?.counters.contains { $0.id == "nested" } == false)
}

struct NativeAlertPersistenceTests {
    private func fixture() throws -> (URL, LocalStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PulseAlertTests-\(UUID().uuidString)", isDirectory: true)
        return (directory, try LocalStore(databaseURL: directory.appendingPathComponent("cache.sqlite")))
    }
    private func counter(_ id: String, _ value: Int64) -> CounterAlertObservation {
        CounterAlertObservation(id: id, label: id.capitalized, value: value,
                                unitSingular: id == "accounts" ? "subscribed account" : "booking",
                                unitPlural: id == "accounts" ? "subscribed accounts" : "bookings")
    }
    private func snapshot(_ id: UUID, counters: [CounterAlertObservation] = [], daily: [DailyAlertObservation] = [], now: Date = Date()) -> ProjectSnapshot {
        ProjectSnapshot(projectID: id, metrics: [], measuredAt: now, fetchedAt: now,
                        alertObservations: AlertObservations(counters: counters, daily: daily))
    }
    private func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    @Test func counterIncreasesGroupOnceAndRemainDeduplicatedAfterRestart() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), now = Date()
        #expect(try await store.acceptSnapshot(snapshot(id, counters: [counter("accounts", 10), counter("bookings", 100)], now: now), notificationsEnabled: true).isEmpty)
        let current = snapshot(id, counters: [counter("accounts", 12), counter("bookings", 114)], now: now.addingTimeInterval(1))
        let pending = try await store.acceptSnapshot(current, notificationsEnabled: true)
        #expect(pending.count == 1)
        #expect(pending.first?.title == "2 more subscribed accounts · 14 more bookings")
        #expect(try await store.loadSnapshots().first?.events.isEmpty == true)
        let event = try #require(pending.first)
        try await store.markNotified(projectID: id, eventID: event.id)
        #expect(try await store.acceptSnapshot(current, notificationsEnabled: true).isEmpty)
        let reopened = try LocalStore(databaseURL: directory.appendingPathComponent("cache.sqlite"))
        #expect(try await reopened.acceptSnapshot(current, notificationsEnabled: true).isEmpty)
        #expect(try await reopened.eventsForDisplay(projectID: id).count == 1)
    }

    @Test func counterDecreasesAreQuietAndNewObservationsStartWithTheirOwnBaseline() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), now = Date()
        try await store.acceptSnapshot(snapshot(id, counters: [counter("accounts", 20)], now: now), notificationsEnabled: true)
        #expect(try await store.acceptSnapshot(snapshot(id, counters: [counter("accounts", 18)], now: now.addingTimeInterval(1)), notificationsEnabled: true).isEmpty)
        let events = try await store.acceptSnapshot(snapshot(id, counters: [counter("accounts", 19), counter("bookings", 500)], now: now.addingTimeInterval(2)), notificationsEnabled: true)
        #expect(events.count == 1)
        #expect(events.first?.title == "1 more subscribed account")
    }

    @Test func dailyComparisonUsesCompleteYesterdayAndOnlyAnnouncesOncePerDay() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), now = Date()
        let yesterdayDate = now.addingTimeInterval(-86_400)
        func daily(_ today: Int64, _ yesterday: Int64, _ date: Date) -> DailyAlertObservation {
            DailyAlertObservation(id: "bookings", label: "Bookings", today: today, yesterday: yesterday, day: day(date))
        }
        try await store.acceptSnapshot(snapshot(id, daily: [daily(8, 10, yesterdayDate)], now: yesterdayDate), notificationsEnabled: true)
        let crossing = try await store.acceptSnapshot(snapshot(id, daily: [daily(11, 10, yesterdayDate)], now: yesterdayDate.addingTimeInterval(1)), notificationsEnabled: true)
        let event = try #require(crossing.first)
        #expect(event.title.contains("1 more today than yesterday (11 vs 10)"))
        try await store.markNotified(projectID: id, eventID: event.id)
        #expect(try await store.acceptSnapshot(snapshot(id, daily: [daily(15, 10, yesterdayDate)], now: yesterdayDate.addingTimeInterval(2)), notificationsEnabled: true).isEmpty)
        let reopened = try LocalStore(databaseURL: directory.appendingPathComponent("cache.sqlite"))
        #expect(try await reopened.acceptSnapshot(snapshot(id, daily: [daily(16, 10, yesterdayDate)], now: yesterdayDate.addingTimeInterval(3)), notificationsEnabled: true).isEmpty)
        #expect(try await reopened.acceptSnapshot(snapshot(id, daily: [daily(20, 16, now)], now: now), notificationsEnabled: true).count == 1)
    }

    @Test func initialDailyLeadAndOptedOutChangesNeverBackfillOnEnable() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), now = Date()
        func daily(_ today: Int64) -> DailyAlertObservation {
            DailyAlertObservation(id: "bookings", label: "Bookings", today: today, yesterday: 10, day: day(now))
        }
        try await store.acceptSnapshot(snapshot(id, counters: [counter("accounts", 10)], daily: [daily(12)], now: now), notificationsEnabled: true)
        #expect(try await store.acceptSnapshot(snapshot(id, counters: [counter("accounts", 10)], daily: [daily(20)], now: now.addingTimeInterval(1)), notificationsEnabled: true).isEmpty)
        try await store.acceptSnapshot(snapshot(id, counters: [counter("accounts", 40)], daily: [daily(30)], now: now.addingTimeInterval(2)), notificationsEnabled: false)
        #expect(try await store.acceptSnapshot(snapshot(id, counters: [counter("accounts", 40)], daily: [daily(30)], now: now.addingTimeInterval(3)), notificationsEnabled: true).isEmpty)
        #expect(try await store.acceptSnapshot(snapshot(id, counters: [counter("accounts", 41)], daily: [daily(31)], now: now.addingTimeInterval(4)), notificationsEnabled: true).first?.title == "1 more subscribed account")
    }

    @Test func rangeSwitchingDoesNotReplayAlertsAndOldObservationsCannotRollbackBaseline() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), now = Date()
        try await store.acceptSnapshot(snapshot(id, counters: [counter("accounts", 10)], now: now), notificationsEnabled: true)
        var current = snapshot(id, counters: [counter("accounts", 20)], now: now.addingTimeInterval(2))
        current.ranges = ["24h": MetricRangeSnapshot(metrics: []), "7d": MetricRangeSnapshot(metrics: [])]
        let event = try #require(try await store.acceptSnapshot(current, notificationsEnabled: true).first)
        try await store.markNotified(projectID: id, eventID: event.id)
        let display = try #require(current.forRange(.last24Hours))
        #expect(try await store.acceptSnapshot(display, notificationsEnabled: true).isEmpty)
        #expect(try await store.acceptSnapshot(snapshot(id, counters: [counter("accounts", 15)], now: now.addingTimeInterval(1)), notificationsEnabled: true).isEmpty)
        #expect(try await store.acceptSnapshot(snapshot(id, counters: [counter("accounts", 21)], now: now.addingTimeInterval(3)), notificationsEnabled: true).first?.title == "1 more subscribed account")
    }

    @Test func changedCredentialsAndRemovedProjectsClearNativeAlertState() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        var connection = rangeConnection()
        try await store.saveConnections([connection])
        try await store.acceptSnapshot(snapshot(connection.id, counters: [counter("accounts", 10)], now: now), notificationsEnabled: true, expectedConnection: connection)
        #expect(try await store.acceptSnapshot(snapshot(connection.id, counters: [counter("accounts", 11)], now: now.addingTimeInterval(1)), notificationsEnabled: true, expectedConnection: connection).count == 1)
        connection.credentialVersion = UUID()
        try await store.saveConnections([connection])
        #expect(try await store.acceptSnapshot(snapshot(connection.id, counters: [counter("accounts", 100)], now: now.addingTimeInterval(2)), notificationsEnabled: true, expectedConnection: connection).isEmpty)
        #expect(try await store.acceptSnapshot(snapshot(connection.id, counters: [counter("accounts", 101)], now: now.addingTimeInterval(3)), notificationsEnabled: true, expectedConnection: connection).first?.title == "1 more subscribed account")
        try await store.removeProject(connection.id)
        try await store.saveConnections([connection])
        #expect(try await store.acceptSnapshot(snapshot(connection.id, counters: [counter("accounts", 500)], now: now.addingTimeInterval(4)), notificationsEnabled: true, expectedConnection: connection).isEmpty)
    }
}
