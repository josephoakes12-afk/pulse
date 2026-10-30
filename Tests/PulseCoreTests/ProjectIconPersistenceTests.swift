import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PulseCore

struct ProjectIconPersistenceTests {
    private func fixture() throws -> (URL, LocalStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PulseIconTests-\(UUID().uuidString)", isDirectory: true)
        return (directory, try LocalStore(databaseURL: directory.appendingPathComponent("cache.sqlite")))
    }

    private func thumbnail(dimension: Int = 32) throws -> Data {
        let context = try #require(CGContext(data: nil, width: dimension, height: dimension, bitsPerComponent: 8,
                                           bytesPerRow: dimension * 4, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.15, green: 0.35, blue: 0.85, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func previousConnectionsDecodeWithoutImageFieldAndNewImageRoundTrips() throws {
        let oldJSON = Data(#"{"id":"10000000-0000-0000-0000-000000000001","name":"Existing project","symbol":"calendar","kind":"http","endpoint":"https://example.com/api/summary","query":"","authHeader":"Authorization","credentialVersion":"20000000-0000-0000-0000-000000000001","metrics":[],"intervalSeconds":300,"notificationsEnabled":false,"enabled":true,"link":""}"#.utf8)
        let old = try JSONDecoder().decode(ProjectConnection.self, from: oldJSON)
        #expect(old.iconImageData == nil)
        #expect(old.symbol == "calendar")
        var changed = old
        changed.iconImageData = try thumbnail()
        let decoded = try JSONDecoder().decode(ProjectConnection.self, from: JSONEncoder().encode(changed))
        #expect(decoded == changed)
    }

    @Test func iconOnlyEditPreservesLatestSettingsSnapshotsEventsAndBaseline() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var latest = ProjectConnection(name: "Before", endpoint: "https://example.invalid/summary",
                                       metrics: [MetricDefinition(label: "Bookings", path: "bookings")], notificationsEnabled: true)
        try await store.saveConnections([latest])
        let now = Date()
        let baseline = ProjectSnapshot(projectID: latest.id, metrics: [], fetchedAt: now)
        try await store.acceptSnapshot(baseline, notificationsEnabled: true, expectedConnection: latest)
        let event = PulseEvent(id: "new", title: "New business", occurredAt: now)
        let snapshot = ProjectSnapshot(projectID: latest.id, metrics: [], events: [event], fetchedAt: now)
        #expect(try await store.acceptSnapshot(snapshot, notificationsEnabled: true, expectedConnection: latest).map(\.id) == ["new"])
        // A picker opened before this ordinary edit must preserve the latest settings.
        latest.name = "Renamed after picker opened"
        latest.intervalSeconds = 900
        latest.link = "https://example.invalid/project"
        try await store.saveConnections([latest])

        let image = try thumbnail()
        let returned = try await store.updateIcon(projectID: latest.id, symbol: "heart.fill", imageData: image)
        var expected = latest
        expected.symbol = "heart.fill"
        expected.iconImageData = image
        #expect(returned == expected)
        #expect(try await store.loadConnections() == [expected])
        #expect(try await store.loadSnapshots() == [snapshot])
        #expect(try await store.eventsForDisplay(projectID: latest.id) == [event])
        #expect(try await store.pendingNotifications(projectID: latest.id) == [event])
        #expect(returned.credentialVersion == latest.credentialVersion)

        try await store.markNotified(projectID: latest.id, eventID: event.id)
        // The old receipt stays delivered; icon edits do not erase event deduplication.
        #expect(try await store.acceptSnapshot(snapshot, notificationsEnabled: true, expectedConnection: expected).isEmpty)
        let later = PulseEvent(id: "later", title: "Another business", occurredAt: now)
        var nextSnapshot = snapshot
        nextSnapshot.events = [later]
        #expect(try await store.acceptSnapshot(nextSnapshot, notificationsEnabled: true, expectedConnection: expected).map(\.id) == ["later"])

        let reopened = try LocalStore(databaseURL: directory.appendingPathComponent("cache.sqlite"))
        #expect(try await reopened.loadConnections() == [expected])
        let symbolOnly = try await reopened.updateIcon(projectID: latest.id, symbol: "calendar", imageData: nil)
        #expect(symbolOnly.iconImageData == nil)
        #expect(symbolOnly.credentialVersion == expected.credentialVersion)
        #expect(try await reopened.pendingNotifications(projectID: latest.id).map(\.id) == ["later"])
    }

    @Test func changedSourceSettingsAreNotOverwrittenByAnOpenIconPicker() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var latest = ProjectConnection(name: "Project", endpoint: "https://example.invalid/old")
        try await store.saveConnections([latest])
        latest.endpoint = "https://example.invalid/new"
        latest.credentialVersion = UUID()
        latest.query = "SELECT count(*) AS users FROM accounts"
        try await store.saveConnections([latest])
        let updated = try await store.updateIcon(projectID: latest.id, symbol: "star.fill", imageData: nil)
        #expect(updated.endpoint == latest.endpoint)
        #expect(updated.query == latest.query)
        #expect(updated.credentialVersion == latest.credentialVersion)
    }

    @Test func oversizedInvalidAndOversizedPixelImagesAreRejectedWithoutChangingConnection() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = ProjectConnection(name: "Keep me", symbol: "calendar")
        try await store.saveConnections([connection])
        for invalid in [Data(repeating: 0, count: ProjectIconLimits.maximumImageBytes + 1), Data("not an image".utf8), try thumbnail(dimension: 129)] {
            do {
                try await store.updateIcon(projectID: connection.id, symbol: "star", imageData: invalid)
                Issue.record("Invalid icon data should be rejected")
            } catch {}
            #expect(try await store.loadConnections() == [connection])
        }
        do {
            try await store.updateIcon(projectID: connection.id, symbol: "../outside.png", imageData: nil)
            Issue.record("A path should not be accepted as a symbol name")
        } catch {}
        #expect(try await store.loadConnections() == [connection])

        var invalidSetup = connection
        invalidSetup.iconImageData = Data(repeating: 0, count: ProjectIconLimits.maximumImageBytes + 1)
        do {
            try await store.saveConnections([invalidSetup])
            Issue.record("Setup should apply the same image size bound")
        } catch {}
        #expect(try await store.loadConnections() == [connection])
    }

    @Test func updatingRemovedProjectCannotResurrectIt() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = ProjectConnection(name: "Removed")
        try await store.saveConnections([connection])
        try await store.removeProject(connection.id)
        do {
            try await store.updateIcon(projectID: connection.id, symbol: "star", imageData: try thumbnail())
            Issue.record("Removed projects must reject a late icon update")
        } catch {}
        #expect(try await store.loadConnections().isEmpty)
        #expect(try await store.loadSnapshots().isEmpty)
        #expect(try await store.eventsForDisplay().isEmpty)
    }

    @Test func iconEditDoesNotDiscardAnInFlightFirstCollection() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = ProjectConnection(name: "Loading project", endpoint: "https://example.invalid/summary",
                                         metrics: [MetricDefinition(label: "Users", path: "users")], notificationsEnabled: true)
        try await store.saveConnections([original])
        let changedIcon = try await store.updateIcon(projectID: original.id, symbol: "star.fill", imageData: try thumbnail())
        let now = Date()
        let oldEvent = PulseEvent(id: "existing", title: "Existing account", occurredAt: now.addingTimeInterval(-300))
        let first = ProjectSnapshot(projectID: original.id,
                                    metrics: [MetricValue(id: original.metrics[0].id, label: "Users", value: "42")],
                                    events: [oldEvent], measuredAt: now, fetchedAt: now)
        // The response started with the old icon, but its source settings still match.
        #expect(try await store.acceptSnapshot(first, notificationsEnabled: true, expectedConnection: original).isEmpty)
        #expect(try await store.loadSnapshots() == [first])
        #expect(try await store.loadConnections() == [changedIcon])
        #expect(try await store.eventsForDisplay(projectID: original.id) == [oldEvent])

        let newEvent = PulseEvent(id: "new", title: "New account", occurredAt: now)
        var second = first
        second.events = [oldEvent, newEvent]
        #expect(try await store.acceptSnapshot(second, notificationsEnabled: true, expectedConnection: original).map(\.id) == [newEvent.id])
        #expect(try await store.loadConnections() == [changedIcon])
    }

    @Test func collectionComparisonIgnoresOnlyTheTwoIconFields() throws {
        let original = ProjectConnection(name: "Project", endpoint: "https://example.invalid/summary",
                                         metrics: [MetricDefinition(label: "Users", path: "users")], notificationsEnabled: true)
        var iconOnly = original
        iconOnly.symbol = "heart.fill"
        iconOnly.iconImageData = try thumbnail()
        #expect(original.hasSameCollectionConfiguration(as: iconOnly))
        #expect(iconOnly.hasSameCollectionConfiguration(as: original))

        var changed = iconOnly
        changed.endpoint += "/other"
        #expect(!original.hasSameCollectionConfiguration(as: changed))
        changed = iconOnly
        changed.credentialVersion = UUID()
        #expect(!original.hasSameCollectionConfiguration(as: changed))
        changed = iconOnly
        changed.metrics[0].path = "otherUsers"
        #expect(!original.hasSameCollectionConfiguration(as: changed))
        changed = iconOnly
        changed.notificationsEnabled = false
        #expect(!original.hasSameCollectionConfiguration(as: changed))
        changed = iconOnly
        changed.enabled = false
        #expect(!original.hasSameCollectionConfiguration(as: changed))
        changed = iconOnly
        changed.name = "Renamed"
        #expect(!original.hasSameCollectionConfiguration(as: changed))
    }

    @Test func iconComparisonStillRejectsAnInFlightResponseWithChangedMetricMapping() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = ProjectConnection(name: "Project", endpoint: "https://example.invalid/summary",
                                         metrics: [MetricDefinition(label: "Users", path: "users")])
        try await store.saveConnections([original])
        var edited = original
        edited.metrics[0].path = "newUsers"
        try await store.saveConnections([edited])
        let oldResponse = ProjectSnapshot(projectID: original.id, metrics: [MetricValue(id: original.metrics[0].id, label: "Users", value: "42")])
        #expect(try await store.acceptSnapshot(oldResponse, notificationsEnabled: false, expectedConnection: original).isEmpty)
        #expect(try await store.loadSnapshots().isEmpty)
        #expect(try await store.loadConnections() == [edited])
    }
}
