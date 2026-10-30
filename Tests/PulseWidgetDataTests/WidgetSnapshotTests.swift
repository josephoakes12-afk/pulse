import Foundation
import Testing
@testable import PulseWidgetData

struct WidgetSnapshotTests {
    private func fixture() -> WidgetSnapshot {
        let metric = WidgetMetric(id: UUID(), label: "Accounts", value: "12")
        let range = WidgetRange(rawValue: "7d", title: "7d", measuredAt: Date(timeIntervalSinceReferenceDate: 100), metrics: [metric])
        return WidgetSnapshot(generatedAt: Date(timeIntervalSinceReferenceDate: 200), projects: [
            WidgetProject(id: UUID(), name: "Studio", symbol: "calendar", ranges: [range])
        ])
    }

    private func store() -> WidgetSnapshotStore {
        WidgetSnapshotStore(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("PulseWidgetTests-\(UUID().uuidString)", isDirectory: true))
    }

    @Test func atomicSnapshotRoundTripsWithPrivatePermissionsAndNoSourceSettings() throws {
        let store = store(), snapshot = fixture()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        #expect(store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.directoryURL.path))
        try store.save(snapshot)
        #expect(store.load() == snapshot)
        let files = FileManager.default
        #expect((try files.attributesOfItem(atPath: store.directoryURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try files.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try files.contentsOfDirectory(atPath: store.directoryURL.path) == [WidgetSnapshotStore.fileName])
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        #expect(Set(object.keys) == ["schemaVersion", "generatedAt", "defaultRangeRawValue", "projects"])
        let project = try #require((object["projects"] as? [[String: Any]])?.first)
        #expect(Set(project.keys) == ["id", "name", "symbol", "enabled", "hasError", "ranges"])
        let range = try #require((project["ranges"] as? [[String: Any]])?.first)
        #expect(Set(range.keys) == ["rawValue", "title", "measuredAt", "metrics"])
        let metric = try #require((range["metrics"] as? [[String: Any]])?.first)
        #expect(Set(metric.keys) == ["id", "label", "value"])
    }

    @Test func configuredProjectNeverFallsBackWhenRemovedPausedOrMissingHistory() throws {
        var snapshot = fixture()
        var paused = snapshot.projects[0]
        paused.id = UUID()
        paused.name = "Paused"
        paused.enabled = false
        snapshot.projects.insert(paused, at: 0)
        #expect(snapshot.project(id: nil)?.name == "Studio")
        #expect(snapshot.project(id: paused.id)?.name == "Paused")
        #expect(snapshot.overview().map(\.name) == ["Studio"])
        #expect(snapshot.project(id: paused.id, rangeRawValue: "30d") == nil)
        #expect(snapshot.project(id: nil, rangeRawValue: "30d") == nil)
        #expect(snapshot.overview(rangeRawValue: "30d").isEmpty)
        #expect(snapshot.project(id: paused.id, rangeRawValue: "invalid") == nil)
        snapshot.projects.removeAll { $0.id == paused.id }
        #expect(snapshot.project(id: paused.id) == nil)
        #expect(snapshot.project(id: nil)?.name == "Studio")
    }

    @Test func overviewPreservesOrderHonoursRangeAndNeverExceedsThreeProjects() throws {
        var snapshot = fixture()
        let first = try #require(snapshot.projects.first)
        snapshot.projects = (0..<5).map {
            var project = first
            project.id = UUID()
            project.name = "Project \($0)"
            return project
        }
        snapshot.projects[0].enabled = false
        snapshot.projects[1].ranges = []
        #expect(snapshot.overview(limit: 100).map(\.name) == ["Project 2", "Project 3", "Project 4"])
        #expect(snapshot.overview(limit: 1).map(\.name) == ["Project 2"])
        #expect(snapshot.overview(limit: -1).isEmpty)
        snapshot.defaultRangeRawValue = "lifetime"
        #expect(snapshot.overview().isEmpty)
        #expect(snapshot.overview(rangeRawValue: "7d").count == 3)
    }

    @Test func replacingSnapshotRemovesOldProjectsAndSupportsAnEmptyState() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let original = fixture()
        let removedID = try #require(original.projects.first?.id)
        try store.save(original)
        try store.save(WidgetSnapshot(projects: []))
        let empty = try #require(store.load())
        #expect(empty.projects.isEmpty)
        #expect(empty.project(id: removedID) == nil)
        #expect(empty.project(id: nil) == nil)
    }

    @Test func corruptUnsupportedAndOversizedFilesFailClosed() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        try store.save(fixture())
        try Data("{broken".utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
        var unsupported = fixture()
        unsupported.schemaVersion = 2
        try JSONEncoder().encode(unsupported).write(to: store.fileURL)
        #expect(store.load() == nil)
        try Data(repeating: 0x20, count: WidgetSnapshotStore.maximumSnapshotBytes + 1).write(to: store.fileURL)
        #expect(store.load() == nil)
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
        #expect(store.load() == nil)
    }

    @Test func invalidWritesKeepThePreviousValidSnapshot() throws {
        let store = store(), original = fixture()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        try store.save(original)
        var duplicate = original
        duplicate.projects.append(duplicate.projects[0])
        #expect(throws: WidgetSnapshotError.invalidSnapshot) { try store.save(duplicate) }
        #expect(store.load() == original)
        var invalidRange = original
        invalidRange.projects[0].ranges[0].rawValue = "90d"
        #expect(throws: WidgetSnapshotError.invalidSnapshot) { try store.save(invalidRange) }
        var tooManyMetrics = original
        let metric = tooManyMetrics.projects[0].ranges[0].metrics[0]
        tooManyMetrics.projects[0].ranges[0].metrics = (0..<4).map { _ in
            WidgetMetric(id: UUID(), label: metric.label, value: metric.value)
        }
        #expect(throws: WidgetSnapshotError.invalidSnapshot) { try store.save(tooManyMetrics) }
        var icon = original
        icon.projects[0].iconImageData = Data(repeating: 0, count: WidgetSnapshot.maximumIconBytes + 1)
        #expect(throws: WidgetSnapshotError.invalidSnapshot) { try store.save(icon) }
        #expect(store.load() == original)
    }

    @Test func totalEncodedSizeIsBoundedEvenWhenIndividualProjectsAreValid() throws {
        let store = store(), original = fixture()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        try store.save(original)
        var large = original
        let project = try #require(original.projects.first)
        large.projects = (0..<32).map { _ in
            var copy = project
            copy.id = UUID()
            copy.iconImageData = Data(repeating: 0, count: WidgetSnapshot.maximumIconBytes)
            return copy
        }
        try large.validate()
        #expect(throws: WidgetSnapshotError.snapshotTooLarge) { try store.save(large) }
        #expect(store.load() == original)
    }

    @Test func directorySymlinksAreNotFollowedOrTightened() throws {
        let base = store().directoryURL
        let realDirectory = base.appendingPathComponent("Existing", isDirectory: true)
        let linkDirectory = base.appendingPathComponent("Widget", isDirectory: true)
        let files = FileManager.default
        defer { try? files.removeItem(at: base) }
        try files.createDirectory(at: realDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try files.createSymbolicLink(at: linkDirectory, withDestinationURL: realDirectory)
        let linkedStore = WidgetSnapshotStore(directoryURL: linkDirectory)
        #expect(linkedStore.load() == nil)
        #expect(throws: WidgetSnapshotError.invalidSnapshot) { try linkedStore.save(fixture()) }
        #expect((try files.attributesOfItem(atPath: realDirectory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        #expect(!files.fileExists(atPath: realDirectory.appendingPathComponent(WidgetSnapshotStore.fileName).path))
    }
}
