import Foundation
import Testing
@testable import Pulse
import PulseCore

@Suite @MainActor struct AppStoreDistributionTests {
    @Test func storeDistributionCannotRequestOrOpenADirectUpdate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let info: [String: String] = ["CFBundleIdentifier": "local.pulse.distribution-test", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "6", "PulseDistributionChannel": "app-store"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: directory))
        let preferences = AppPreferences(bundle: bundle, releaseClient: PulseReleaseClient(transport: { _ in
            Issue.record("A Store build must never request a GitHub update")
            throw CancellationError()
        }))
        #expect(!preferences.canCheckForUpdates)
        #expect(!preferences.canConfigureLoginItem)
        await preferences.checkForUpdates()
        preferences.openAvailableRelease()
        #expect(preferences.updateMessage == nil)
        #expect(!preferences.checkingForUpdates)
        #expect(preferences.availableReleaseURL == nil)
    }

    @Test func exampleWindowHasNoPersistenceOrCloudAndKeepsPresentationChangesInMemory() async throws {
        let store = AppStore(examplesOnly: true)
        await store.start()
        #expect(store.examplesOnly)
        #expect(store.isDemo)
        #expect(store.connections.isEmpty)
        #expect(store.displayedConnections.map(\.name) == ["Booking Studio", "Playroom", "The Daily"])
        #expect(!store.cloudSyncStatus.configured)
        await store.setCloudSyncEnabled(true)
        #expect(!store.cloudSyncStatus.enabled)
        #expect(store.cloudSummary == nil)
        #expect(store.widgetSnapshot().projects.isEmpty)
        let project = try #require(store.displayedConnections.first)
        let extra = try #require(store.snapshot(for: project.id)?.details?.first)
        try await store.setMetricVisible(true, metricID: extra.id, projectID: project.id, placement: .headline)
        #expect(store.snapshot(for: project.id)?.metrics.contains(where: { $0.id == extra.id }) == true)
        try await store.updateIcon(projectID: project.id, symbol: "star", imageData: nil)
        #expect(store.displayedConnections.first?.symbol == "star")
        let otherWindow = AppStore(examplesOnly: true)
        #expect(otherWindow.displayedConnections.first?.symbol == "calendar")
        #expect(otherWindow.snapshot(for: project.id)?.metrics.count == 2)
        store.selectRange(.last24Hours)
        #expect(store.snapshot(for: project.id)?.metrics.first?.value == "2")
        await store.refreshAll()
        #expect(store.errors.isEmpty)
        #expect(store.refreshing.isEmpty)
    }

    @Test func distributionMetadataIsExplicit() {
        #expect(PulseDistribution(channel: "app-store") == .appStore)
        #expect(!PulseDistribution(channel: "app-store").allowsDirectUpdates)
        #expect(PulseDistribution(channel: nil) == .direct)
        #expect(PulseDistribution(channel: "direct").allowsDirectUpdates)
    }
}
