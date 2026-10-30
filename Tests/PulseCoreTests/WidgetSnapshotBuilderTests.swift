import Foundation
import PulseWidgetData
import Testing
@testable import PulseCore

@Suite struct WidgetSnapshotBuilderTests {
    @Test func onlyVisibleAggregatesLeaveTheAppAndUnavailableHistoryStaysUnavailable() throws {
        let id = UUID(), first = UUID(), second = UUID()
        let connection = ProjectConnection(id: id, name: "Studio", symbol: "calendar", endpoint: "https://private.invalid/secret-endpoint", query: "secret SQL", authHeader: "Secret-Header")
        let metrics = [MetricValue(id: first, label: "Accounts", value: "0"), MetricValue(id: second, label: "Bookings", value: "12")]
        let source = ProjectSnapshot(projectID: id, metrics: metrics, events: [PulseEvent(id: "private-event", title: "Private Person", occurredAt: .now, url: "https://private.invalid/person")],
                                     coverage: "Private source details", details: [MetricValue(id: UUID(), label: "Private detail", value: "1")],
                                     ranges: ["24h": MetricRangeSnapshot(metrics: metrics), "7d": MetricRangeSnapshot(metrics: metrics)])
        let exported = WidgetSnapshotBuilder.make(connections: [connection], snapshots: [id: source], visibility: [id: MetricVisibility(hiddenMetricIDs: [second])], defaultRange: .last7Days)
        try exported.validate()
        #expect(exported.projects[0].range(rawValue: "7d")?.metrics.map { $0.value } == ["0"])
        #expect(exported.projects[0].range(rawValue: "30d") == nil)
        #expect(exported.projects[0].range(rawValue: "lifetime") == nil)
        let json = String(decoding: try JSONEncoder().encode(exported), as: UTF8.self)
        for secret in ["private.invalid", "secret SQL", "Secret-Header", "Private Person", "Private detail", "private-event", "Private source details"] {
            #expect(!json.contains(secret))
        }
        let removed = WidgetSnapshotBuilder.make(connections: [], snapshots: [id: source], visibility: [:], defaultRange: .last7Days)
        #expect(removed.projects.isEmpty)
    }

    @Test func iconAndUnicodeBudgetsKeepLargeProjectCollectionsExportable() throws {
        let icon = Data(repeating: 1, count: 64 * 1024)
        let name = String(repeating: "👨‍👩‍👧‍👦", count: 60)
        let projects = (0..<50).map { _ in ProjectConnection(name: name, symbol: "star", iconImageData: icon) }
        let sources = Dictionary(uniqueKeysWithValues: projects.map {
            ($0.id, ProjectSnapshot(projectID: $0.id, metrics: [MetricValue(id: UUID(), label: name, value: "0")]))
        })
        let snapshot = WidgetSnapshotBuilder.make(connections: projects, snapshots: sources, visibility: [:], defaultRange: .lifetime)
        try snapshot.validate()
        #expect(snapshot.projects.count == 50)
        #expect(snapshot.projects.reduce(0) { $0 + ($1.iconImageData?.count ?? 0) } <= 512 * 1024)
        #expect(try JSONEncoder().encode(snapshot).count < WidgetSnapshotStore.maximumSnapshotBytes)
    }

    @Test func pendingOrEmptySourcesDoNotInvalidateOtherWidgetProjects() throws {
        let ready = ProjectConnection(name: "Ready", symbol: "star")
        let empty = ProjectConnection(name: "Empty", symbol: "star")
        let pending = ProjectConnection(name: "Pending", symbol: "star")
        let snapshot = WidgetSnapshotBuilder.make(connections: [pending, empty, ready], snapshots: [
            empty.id: ProjectSnapshot(projectID: empty.id, metrics: []),
            ready.id: ProjectSnapshot(projectID: ready.id, metrics: [MetricValue(id: UUID(), label: "Accounts", value: "4")])
        ], visibility: [:], defaultRange: .lifetime, errors: [empty.id])
        try snapshot.validate()
        #expect(snapshot.project(id: nil)?.id == ready.id)
        #expect(snapshot.projects.first { $0.id == empty.id }?.hasError == true)
    }

    @Test func deepLinksOnlyAcceptLocalWidgetActionsAndKnownRanges() {
        let id = UUID()
        let link = WidgetDeepLink(url: URL(string: "pulse-metrics://project/\(id)?range=7d")!)
        #expect(link?.projectID == id)
        #expect(link?.range == .last7Days)
        #expect(WidgetDeepLink(url: URL(string: "pulse-metrics://open")!) != nil)
        for invalid in ["https://project/\(id)", "pulse-metrics://project/no-id", "pulse-metrics://open/extra", "pulse-metrics://project/\(id)?range=bad", "pulse-metrics://open?range=7d&range=24h", "pulse-metrics://user:secret@open", "pulse-metrics://delete/\(id)"] {
            #expect(WidgetDeepLink(url: URL(string: invalid)!) == nil)
        }
    }
}
