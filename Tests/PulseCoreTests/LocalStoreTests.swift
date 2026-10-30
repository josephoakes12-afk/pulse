import Foundation
import Testing
@testable import PulseCore

struct LocalStoreTests {
    private func fixture() throws -> (URL, LocalStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PulseStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (directory, try LocalStore(databaseURL: directory.appendingPathComponent("cache.sqlite")))
    }

    private func snapshot(_ id: UUID, events: [PulseEvent] = [], now: Date = Date()) -> ProjectSnapshot {
        ProjectSnapshot(projectID: id, metrics: [MetricValue(id: UUID(), label: "games", value: "8")], events: events, measuredAt: now, fetchedAt: now)
    }

    @Test func firstCollectionIsSilentThenDeliveryIsDeduplicated() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), now = Date()
        let old = PulseEvent(id: "old", title: "An existing account", occurredAt: now.addingTimeInterval(-100))
        let new = PulseEvent(id: "new", title: "A new account", occurredAt: now)
        #expect(try await store.acceptSnapshot(snapshot(id, events: [old], now: now), notificationsEnabled: true).isEmpty)
        let second = try await store.acceptSnapshot(snapshot(id, events: [old, new], now: now), notificationsEnabled: true)
        #expect(second.map(\.id) == ["new"])
        // Failed notification transport can ask again without losing the event.
        #expect(try await store.acceptSnapshot(snapshot(id, events: [new], now: now), notificationsEnabled: true).map(\.id) == ["new"])
        try await store.markNotified(projectID: id, eventID: new.id)
        #expect(try await store.acceptSnapshot(snapshot(id, events: [old, new], now: now), notificationsEnabled: true).isEmpty)
    }

    @Test func pendingReceiptSurvivesRestart() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), now = Date()
        try await store.acceptSnapshot(snapshot(id, now: now), notificationsEnabled: true)
        let event = PulseEvent(id: "persisted", title: "New business", occurredAt: now)
        try await store.acceptSnapshot(snapshot(id, events: [event], now: now), notificationsEnabled: true)
        let reopened = try LocalStore(databaseURL: directory.appendingPathComponent("cache.sqlite"))
        #expect(try await reopened.pendingNotifications(projectID: id).map(\.id) == [event.id])
        try await reopened.markNotified(projectID: id, eventID: event.id)
        #expect(try await store.pendingNotifications(projectID: id).isEmpty)
    }

    @Test func observedDisabledEventsDoNotAlertWhenEnabledLater() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), now = Date()
        try await store.acceptSnapshot(snapshot(id, now: now), notificationsEnabled: false)
        let event = PulseEvent(id: "disabled", title: "Quiet event", occurredAt: now)
        try await store.acceptSnapshot(snapshot(id, events: [event], now: now), notificationsEnabled: false)
        #expect(try await store.acceptSnapshot(snapshot(id, events: [event], now: now), notificationsEnabled: true).isEmpty)
    }

    @Test func disablingConnectionAlertsSuppressesPendingReceipt() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), now = Date()
        var connection = ProjectConnection(id: id, name: "Project", notificationsEnabled: true)
        try await store.saveConnections([connection])
        try await store.acceptSnapshot(snapshot(id, now: now), notificationsEnabled: true)
        try await store.acceptSnapshot(snapshot(id, events: [PulseEvent(id: "queued", title: "Queued", occurredAt: now)], now: now), notificationsEnabled: true)
        connection.notificationsEnabled = false
        try await store.saveConnections([connection])
        #expect(try await store.pendingNotifications(projectID: id).isEmpty)
    }

    @Test func orderedConnectionsAndSnapshotRoundTrip() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ProjectConnection(name: "B", endpoint: "https://example.invalid/summary")
        let second = ProjectConnection(name: "A", kind: .postgres)
        try await store.saveConnections([first, second])
        #expect(try await store.loadConnections() == [first, second])
        let cached = snapshot(first.id)
        try await store.saveSnapshot(cached)
        #expect(try await store.loadSnapshots() == [cached])
        // Config-only updates must not erase metrics for a retained project.
        try await store.saveConnections([second, first])
        #expect(try await store.loadSnapshots() == [cached])
    }

    @Test func deletingConnectionRemovesOnlyItsLocalData() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ProjectConnection(name: "First"), second = ProjectConnection(name: "Second")
        try await store.saveConnections([first, second])
        try await store.acceptSnapshot(snapshot(first.id, events: [PulseEvent(id: "a", title: "A", occurredAt: Date())]), notificationsEnabled: true)
        try await store.acceptSnapshot(snapshot(second.id, events: [PulseEvent(id: "b", title: "B", occurredAt: Date())]), notificationsEnabled: true)
        try await store.removeProject(first.id)
        #expect(try await store.loadConnections().map(\.id) == [second.id])
        #expect(try await store.loadSnapshots().map(\.projectID) == [second.id])
        #expect(try await store.eventsForDisplay(projectID: first.id).isEmpty)
        #expect(try await store.eventsForDisplay(projectID: second.id).map(\.id) == ["b"])
    }

    @Test func pruningCannotReannounceOldReceipt() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), now = Date()
        let events = (0..<1_005).map { index in
            PulseEvent(id: "event-\(index)", title: "Event \(index)", occurredAt: now.addingTimeInterval(Double(index) - 2_000))
        }
        try await store.acceptSnapshot(snapshot(id, events: events, now: now), notificationsEnabled: true)
        #expect(try await store.eventsForDisplay(projectID: id, limit: 100).count == 100)
        #expect(try await store.acceptSnapshot(snapshot(id, events: [events[0]], now: now), notificationsEnabled: true).isEmpty)
        // The persisted cutoff also survives a process restart.
        let reopened = try LocalStore(databaseURL: directory.appendingPathComponent("cache.sqlite"))
        #expect(try await reopened.acceptSnapshot(snapshot(id, events: [events[1]], now: now), notificationsEnabled: true).isEmpty)
    }

    @Test func notificationsHaveBoundedCatchupAndRejectFutureTimes() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), now = Date()
        try await store.acceptSnapshot(snapshot(id, now: now), notificationsEnabled: true)
        let old = PulseEvent(id: "too-old", title: "Old", occurredAt: now.addingTimeInterval(-8 * 86_400))
        let future = PulseEvent(id: "future", title: "Future", occurredAt: now.addingTimeInterval(600))
        let current = PulseEvent(id: "current", title: "Current", occurredAt: now)
        #expect(try await store.acceptSnapshot(snapshot(id, events: [old, future, current], now: now), notificationsEnabled: true).map(\.id) == ["current"])
    }

    @Test func cacheFilesArePrivateAndDuplicateConfigCannotReplaceExistingData() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = ProjectConnection(name: "Private")
        try await store.saveConnections([connection])
        do {
            try await store.saveConnections([connection, connection])
            Issue.record("Duplicate connections should be rejected")
        } catch {}
        #expect(try await store.loadConnections() == [connection])
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("cache.sqlite").path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func staleResponseCannotOverwriteAnEditedConnection() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let original = ProjectConnection(name: "Original", endpoint: "https://example.invalid/old", notificationsEnabled: true)
        try await store.saveConnections([original])
        let baseline = snapshot(original.id, now: now)
        try await store.acceptSnapshot(baseline, notificationsEnabled: true, expectedConnection: original)
        var edited = original
        edited.endpoint = "https://example.invalid/new"
        try await store.saveConnections([edited])
        let stale = snapshot(original.id, events: [PulseEvent(id: "stale", title: "Old source", occurredAt: now)], now: now)
        #expect(try await store.acceptSnapshot(stale, notificationsEnabled: true, expectedConnection: original).isEmpty)
        #expect(try await store.loadSnapshots().isEmpty)
        #expect(try await store.eventsForDisplay(projectID: original.id).isEmpty)
        #expect(try await store.loadConnections() == [edited])
    }

    @Test func staleResponseCannotResurrectARemovedProject() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = ProjectConnection(name: "Removed", notificationsEnabled: true)
        try await store.saveConnections([connection])
        try await store.acceptSnapshot(snapshot(connection.id), notificationsEnabled: true, expectedConnection: connection)
        try await store.removeProject(connection.id)
        let stale = snapshot(connection.id, events: [PulseEvent(id: "late", title: "Late response", occurredAt: Date())])
        #expect(try await store.acceptSnapshot(stale, notificationsEnabled: true, expectedConnection: connection).isEmpty)
        #expect(try await store.loadConnections().isEmpty)
        #expect(try await store.loadSnapshots().isEmpty)
        #expect(try await store.eventsForDisplay().isEmpty)
        #expect(try await store.pendingNotifications(projectID: connection.id).isEmpty)
    }

    @Test func ordinaryEditsPreserveBaselineButSourceAndCredentialChangesResetIt() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        var connection = ProjectConnection(name: "Before", endpoint: "https://example.invalid/summary", notificationsEnabled: true)
        try await store.saveConnections([connection])
        let old = PulseEvent(id: "existing", title: "Existing account", occurredAt: now)
        let cached = snapshot(connection.id, events: [old], now: now)
        try await store.acceptSnapshot(cached, notificationsEnabled: true, expectedConnection: connection)
        connection.name = "After"
        connection.symbol = "calendar"
        connection.notificationsEnabled = false
        try await store.saveConnections([connection])
        #expect(try await store.loadSnapshots() == [cached])
        #expect(try await store.eventsForDisplay(projectID: connection.id).map(\.id) == [old.id])

        connection.endpoint = "https://example.invalid/another-source"
        connection.notificationsEnabled = true
        try await store.saveConnections([connection])
        #expect(try await store.loadSnapshots().isEmpty)
        #expect(try await store.eventsForDisplay(projectID: connection.id).isEmpty)
        // The new source's historical events are a new silent baseline.
        #expect(try await store.acceptSnapshot(cached, notificationsEnabled: true, expectedConnection: connection).isEmpty)

        connection.credentialVersion = UUID()
        try await store.saveConnections([connection])
        #expect(try await store.loadSnapshots().isEmpty)
        #expect(try await store.eventsForDisplay(projectID: connection.id).isEmpty)
        #expect(try await store.acceptSnapshot(cached, notificationsEnabled: true, expectedConnection: connection).isEmpty)
    }
}
