import Foundation
import Testing
@testable import PulseCore

@Suite struct MetricCatalogSelectionTests {
    private func source() -> ProjectSnapshot {
        let heads = (0..<3).map { MetricValue(id: MetricIdentity.uuid(projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, path: "head.\($0)"), label: "Headline \($0)", value: "\($0)") }
        let details = (0..<14).map { MetricValue(id: UUID(), label: "Extra \($0)", value: "\($0 + 10)") }
        let groups = (0..<4).map { MetricBreakdown(id: "group.\($0)", title: "Group \($0)", rows: [MetricBreakdownRow(id: "one", label: "Example", value: "1")]) }
        return ProjectSnapshot(projectID: UUID(), metrics: heads, details: details, breakdowns: groups,
                               alertObservations: AlertObservations(counters: [CounterAlertObservation(id: "total", label: "Records", value: 12, unitSingular: "record", unitPlural: "records")]))
    }

    @Test func anyCatalogMetricCanReplaceAHeadlineWithoutDuplicatingItInTheDrawer() throws {
        let raw = source(), promoted = try #require(raw.details?[10])
        let choice = MetricVisibility(headlineMetricIDs: [raw.metrics[0].id, promoted.id, raw.metrics[2].id],
                                      detailMetricIDs: [promoted.id, raw.metrics[1].id, raw.details![12].id], visibleBreakdownIDs: ["group.3"])
        let display = raw.applyingVisibility(choice)
        #expect(display.metrics.map(\.id) == [raw.metrics[0].id, promoted.id, raw.metrics[2].id])
        #expect(display.details?.map(\.id) == [raw.metrics[1].id, raw.details![12].id])
        #expect(display.breakdowns?.map(\.id) == ["group.3"])
        #expect(display.alertObservations == raw.alertObservations)
        #expect(raw.metrics.count == 3 && raw.details?.count == 14)
    }

    @Test func defaultsStayCompactAndExplicitEmptyDrawerStaysEmpty() {
        let raw = source()
        let automatic = raw.applyingVisibility(MetricVisibility())
        #expect(automatic.metrics.count == 3)
        #expect(automatic.details?.count == 6)
        #expect(automatic.breakdowns?.count == 2)
        let empty = raw.applyingVisibility(MetricVisibility(detailMetricIDs: [], visibleBreakdownIDs: []))
        #expect(empty.metrics == raw.metrics)
        #expect(empty.details == nil && empty.breakdowns == nil)
    }

    @Test func oldHideOnlyPreferencesDecodeAndSelectionsSurviveRestart() async throws {
        let raw = source(), hidden = raw.metrics[1].id
        let legacy = try JSONDecoder().decode(MetricVisibility.self, from: JSONEncoder().encode(["hiddenMetricIDs": [hidden.uuidString]]))
        #expect(legacy.headlineMetricIDs == nil && legacy.detailMetricIDs == nil)
        #expect(!raw.applyingVisibility(legacy).metrics.contains { $0.id == hidden })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PulseCatalog-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pulse.sqlite")
        let store = try LocalStore(databaseURL: url)
        let connection = ProjectConnection(id: raw.projectID, name: "Example")
        try await store.saveConnections([connection])
        let selection = MetricVisibility(headlineMetricIDs: [raw.details![9].id], detailMetricIDs: [], visibleBreakdownIDs: [])
        try await store.saveMetricVisibility(selection, projectID: raw.projectID)
        let reopened = try LocalStore(databaseURL: url)
        #expect(try await reopened.metricVisibility(projectID: raw.projectID) == selection)
        #expect(try await reopened.loadConnections() == [connection])
    }

    @Test func unavailableSelectionsRecoverACurrentHeadlineAndDoNotAlterOtherRanges() {
        var raw = source()
        raw.ranges = ["7d": MetricRangeSnapshot(metrics: raw.metrics, details: raw.details)]
        let choice = MetricVisibility(headlineMetricIDs: [UUID()], detailMetricIDs: [UUID()], visibleBreakdownIDs: ["missing"])
        let display = raw.applyingVisibility(choice)
        #expect(display.metrics == [raw.metrics[0]])
        #expect(display.details == nil && display.breakdowns == nil)
        #expect(display.ranges == raw.ranges)
    }

    @Test func automaticCatalogUpgradePreservesAlertReceiptsAndBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PulseUpgrade-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(databaseURL: directory.appendingPathComponent("pulse.sqlite"))
        let plan = SupabaseRESTPlan(metrics: [SupabaseRESTMetric(key: "accounts", table: "accounts", timeColumn: "created_at", notificationCounter: true)])
        let connection = ProjectConnection(name: "Example", kind: .supabase, endpoint: "https://abcdefghijklmnopqrst.supabase.co/rest/v1",
                                           query: try plan.encodedQuery(), metrics: [MetricDefinition(label: "Accounts", path: "metrics.accounts")], notificationsEnabled: true)
        try await store.saveConnections([connection])
        let now = Date()
        func snapshot(_ count: Int64, at date: Date) -> ProjectSnapshot {
            ProjectSnapshot(projectID: connection.id, metrics: [MetricValue(id: connection.metrics[0].id, label: "Accounts", value: "\(count)")], measuredAt: date, fetchedAt: date,
                            alertObservations: AlertObservations(counters: [CounterAlertObservation(id: "accounts", label: "Accounts", value: count, unitSingular: "account", unitPlural: "accounts")]))
        }
        try await store.acceptSnapshot(snapshot(10, at: now), notificationsEnabled: true, expectedConnection: connection)
        let pending = try await store.acceptSnapshot(snapshot(11, at: now.addingTimeInterval(1)), notificationsEnabled: true, expectedConnection: connection)
        #expect(pending.count == 1)
        let upgraded = try SupabaseConnector.enrichCountPlan(connection)
        try await store.saveConnections([upgraded])
        #expect(try await store.pendingNotifications(projectID: connection.id) == pending)
        #expect(try await store.loadSnapshots().count == 1)
        for event in pending { try await store.markNotified(projectID: connection.id, eventID: event.id) }
        #expect(try await store.acceptSnapshot(snapshot(11, at: now.addingTimeInterval(2)), notificationsEnabled: true, expectedConnection: upgraded).isEmpty)
        #expect(try await store.acceptSnapshot(snapshot(12, at: now.addingTimeInterval(3)), notificationsEnabled: true, expectedConnection: upgraded).map(\.title) == ["1 more account"])
    }
}
