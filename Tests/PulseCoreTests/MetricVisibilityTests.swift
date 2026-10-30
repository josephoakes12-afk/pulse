import CSQLite
import Foundation
import Testing
@testable import PulseCore

struct MetricVisibilityTests {
    private func fixture() throws -> (URL, LocalStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PulseVisibilityTests-\(UUID().uuidString)", isDirectory: true)
        return (directory, try LocalStore(databaseURL: directory.appendingPathComponent("cache.sqlite")))
    }

    private func connection(_ name: String = "Project") -> ProjectConnection {
        ProjectConnection(name: name, endpoint: "https://example.invalid/summary",
                          metrics: [MetricDefinition(label: "Accounts", path: "accounts"), MetricDefinition(label: "Bookings", path: "bookings")],
                          notificationsEnabled: true)
    }

    private func snapshot(_ source: ProjectConnection, accounts: Int64, events: [PulseEvent] = [], now: Date) -> ProjectSnapshot {
        ProjectSnapshot(projectID: source.id,
                        metrics: [MetricValue(id: source.metrics[0].id, label: "Accounts", value: String(accounts)),
                                  MetricValue(id: source.metrics[1].id, label: "Bookings", value: "20")],
                        events: events, measuredAt: now, fetchedAt: now,
                        alertObservations: AlertObservations(counters: [CounterAlertObservation(id: "accounts", label: "Accounts", value: accounts,
                                                                                               unitSingular: "account", unitPlural: "accounts")]))
    }

    @Test func visibilityIsPerProjectPersistsAfterRestartAndCanReturnToDefaults() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = connection("First"), second = connection("Second")
        try await store.saveConnections([first, second])
        #expect(try await store.metricVisibility(projectID: first.id) == MetricVisibility())
        #expect(try await store.loadMetricVisibility().isEmpty)
        let firstChoice = MetricVisibility(hiddenMetricIDs: [first.metrics[1].id])
        let secondChoice = MetricVisibility(hiddenMetricIDs: [second.metrics[0].id])
        try await store.saveMetricVisibility(firstChoice, projectID: first.id)
        try await store.saveMetricVisibility(secondChoice, projectID: second.id)

        let reopened = try LocalStore(databaseURL: directory.appendingPathComponent("cache.sqlite"))
        #expect(try await reopened.loadMetricVisibility() == [first.id: firstChoice, second.id: secondChoice])
        #expect(try await reopened.loadConnections() == [first, second])
        try await reopened.saveMetricVisibility(MetricVisibility(), projectID: first.id)
        #expect(try await reopened.metricVisibility(projectID: first.id) == MetricVisibility())
        #expect(try await reopened.loadMetricVisibility() == [second.id: secondChoice])

        // Removing a connection through the ordinary configuration save only
        // clears that source's presentation state.
        try await reopened.saveMetricVisibility(firstChoice, projectID: first.id)
        try await reopened.saveConnections([second])
        #expect(try await reopened.loadMetricVisibility() == [second.id: secondChoice])
    }

    @Test func sourceAndIconEditsRetainPreferencesButRemovalRejectsLateChanges() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = connection()
        try await store.saveConnections([source])
        let choice = MetricVisibility(hiddenMetricIDs: [source.metrics[1].id])
        try await store.saveMetricVisibility(choice, projectID: source.id)
        try await store.saveSnapshot(snapshot(source, accounts: 4, now: Date()))

        source.endpoint = "https://example.invalid/another-source"
        source.credentialVersion = UUID()
        try await store.saveConnections([source])
        #expect(try await store.loadSnapshots().isEmpty)
        #expect(try await store.metricVisibility(projectID: source.id) == choice)
        let iconChange = try await store.updateIcon(projectID: source.id, symbol: "heart.fill", imageData: nil)
        #expect(try await store.metricVisibility(projectID: source.id) == choice)
        #expect(try await store.loadConnections() == [iconChange])

        try await store.removeProject(source.id)
        do {
            try await store.saveMetricVisibility(choice, projectID: source.id)
            Issue.record("A late menu action must not recreate a removed connection's preferences")
        } catch {}
        #expect(try await store.loadMetricVisibility().isEmpty)
        #expect(try await store.loadConnections().isEmpty)
    }

    @Test func visibilityChangesPreserveInFlightCollectionPendingAlertsAndCounterBaseline() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = connection(), now = Date()
        let old = PulseEvent(id: "old", title: "An existing account", occurredAt: now.addingTimeInterval(-60))
        try await store.saveConnections([source])
        try await store.acceptSnapshot(snapshot(source, accounts: 10, events: [old], now: now), notificationsEnabled: true, expectedConnection: source)

        let hidden = MetricVisibility(hiddenMetricIDs: [source.metrics[0].id])
        try await store.saveMetricVisibility(hidden, projectID: source.id)
        let new = PulseEvent(id: "new", title: "A new account", occurredAt: now.addingTimeInterval(1))
        let arriving = snapshot(source, accounts: 12, events: [old, new], now: now.addingTimeInterval(1))
        let pending = try await store.acceptSnapshot(arriving, notificationsEnabled: true, expectedConnection: source)
        #expect(Set(pending.map(\.title)) == [new.title, "2 more accounts"])
        #expect(try await store.loadConnections() == [source])
        let cached = try #require(try await store.loadSnapshots().first)
        #expect(cached.metrics == arriving.metrics)
        #expect(cached.alertObservations == arriving.alertObservations)
        #expect(Set(cached.events.map(\.id)) == Set(arriving.events.map(\.id)))
        #expect(arriving.applyingVisibility(hidden).metrics.map(\.id) == [source.metrics[1].id])
        // Re-showing the hidden metric must not erase queued notifications or
        // reset the source's credential/configuration identity.
        try await store.saveMetricVisibility(MetricVisibility(), projectID: source.id)
        #expect(try await store.pendingNotifications(projectID: source.id) == pending)
        for event in pending { try await store.markNotified(projectID: source.id, eventID: event.id) }

        let reopened = try LocalStore(databaseURL: directory.appendingPathComponent("cache.sqlite"))
        #expect(try await reopened.acceptSnapshot(arriving, notificationsEnabled: true, expectedConnection: source).isEmpty)
        let next = snapshot(source, accounts: 13, events: [old, new], now: now.addingTimeInterval(2))
        #expect(try await reopened.acceptSnapshot(next, notificationsEnabled: true, expectedConnection: source).map(\.title) == ["1 more account"])
    }

    @Test func visibilityProjectsEachRangeWithoutAlteringRawMetricsOrAlertObservations() throws {
        let source = connection(), now = Date()
        let detailID = MetricIdentity.uuid(projectID: source.id, path: "details:active")
        let detail = MetricValue(id: detailID, label: "Active", value: "7")
        let rows = [MetricBreakdown(id: "by-account", title: "Bookings by account", rows: [MetricBreakdownRow(id: "example", label: "Example", value: "3")])]
        let event = PulseEvent(id: "current", title: "A new account", occurredAt: now)
        var raw = snapshot(source, accounts: 100, events: [event], now: now)
        raw.coverage = "An example source"
        raw.details = [detail]
        raw.breakdowns = rows
        let daily = [MetricValue(id: source.metrics[0].id, label: "New accounts", value: "0"),
                     MetricValue(id: source.metrics[1].id, label: "Bookings", value: "2")]
        raw.ranges = ["24h": MetricRangeSnapshot(metrics: daily, details: [detail], breakdowns: rows),
                      "lifetime": MetricRangeSnapshot(metrics: raw.metrics, details: [detail], breakdowns: rows)]
        let original = raw
        let choice = MetricVisibility(hiddenMetricIDs: [source.metrics[1].id, detailID])
        for range in [MetricTimeRange.last24Hours, .lifetime] {
            let rangeSnapshot = try #require(raw.forRange(range))
            let visible = rangeSnapshot.applyingVisibility(choice)
            #expect(visible.metrics.map(\.id) == [source.metrics[0].id])
            #expect(visible.metrics.first?.value == (range == .last24Hours ? "0" : "100"))
            #expect(visible.details?.isEmpty != false)
            #expect(visible.breakdowns == rows)
            #expect(visible.events == [event])
            #expect(visible.alertObservations == raw.alertObservations)
            #expect(visible.ranges == raw.ranges)
            #expect(visible.measuredAt == raw.measuredAt)
            #expect(visible.fetchedAt == raw.fetchedAt)
            #expect(visible.coverage == raw.coverage)
        }
        #expect(raw == original)
        #expect(choice.isVisible(source.metrics[0].id))
        #expect(!choice.isVisible(detailID))
    }

    @Test func versionTwoCacheMigrationKeepsSnapshotsReceiptsAndAlertBaseline() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = connection(), now = Date()
        try await store.saveConnections([source])
        try await store.acceptSnapshot(snapshot(source, accounts: 100, now: now), notificationsEnabled: true, expectedConnection: source)
        let current = snapshot(source, accounts: 101, now: now.addingTimeInterval(1))
        let pending = try #require(try await store.acceptSnapshot(current, notificationsEnabled: true, expectedConnection: source).first)
        try versionTwoFixture(databaseURL: directory.appendingPathComponent("cache.sqlite"))

        let migrated = try LocalStore(databaseURL: directory.appendingPathComponent("cache.sqlite"))
        #expect(try await migrated.loadConnections() == [source])
        #expect(try await migrated.loadSnapshots() == [current])
        #expect(try await migrated.loadMetricVisibility().isEmpty)
        #expect(try await migrated.metricVisibility(projectID: source.id) == MetricVisibility())
        #expect(try await migrated.pendingNotifications(projectID: source.id) == [pending])
        try await migrated.markNotified(projectID: source.id, eventID: pending.id)
        #expect(try await migrated.acceptSnapshot(current, notificationsEnabled: true, expectedConnection: source).isEmpty)
        #expect(try await migrated.acceptSnapshot(snapshot(source, accounts: 102, now: now.addingTimeInterval(2)), notificationsEnabled: true,
                                                 expectedConnection: source).map(\.title) == ["1 more account"])
    }

    @Test func stalePreferencesKeepACurrentHeadlineWithoutPromotingOrResurrectingDetails() {
        let source = connection()
        let hiddenDetail = MetricValue(id: UUID(), label: "Active", value: "3")
        let visibleDetail = MetricValue(id: UUID(), label: "Returning", value: "2")
        let hiddenIDs = Set(source.metrics.map(\.id) + [hiddenDetail.id])
        let visibility = MetricVisibility(hiddenMetricIDs: hiddenIDs)
        var raw = snapshot(source, accounts: 100, now: Date())
        raw.details = [hiddenDetail, visibleDetail]
        let firstDisplay = raw.applyingVisibility(visibility)
        #expect(firstDisplay.metrics == [raw.metrics[0]])
        #expect(firstDisplay.details == [visibleDetail])

        // A source can remove or replace headline fields after the user has
        // saved choices. Preserve one number from the current response only.
        raw.metrics.removeFirst()
        let afterSourceShrink = raw.applyingVisibility(visibility)
        #expect(afterSourceShrink.metrics == raw.metrics)
        #expect(afterSourceShrink.metrics.first?.label == "Bookings")
        #expect(afterSourceShrink.details == [visibleDetail])
        raw.metrics = []
        let withoutSourceHeadlines = raw.applyingVisibility(visibility)
        #expect(withoutSourceHeadlines.metrics.isEmpty)
        #expect(withoutSourceHeadlines.details == [visibleDetail])
        #expect(visibility.hiddenMetricIDs == hiddenIDs)
    }

    private func versionTwoFixture(databaseURL: URL) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw MigrationFixtureError.database
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "DROP TABLE IF EXISTS presentation_state; PRAGMA user_version = 2;", nil, nil, nil) == SQLITE_OK else {
            throw MigrationFixtureError.database
        }
    }

    private enum MigrationFixtureError: Error { case database }
}
