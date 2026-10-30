import Combine
import Foundation
import PulseCore
import PulseWidgetData
import WidgetKit

@MainActor
final class WidgetBridge {
    private weak var app: AppStore?
    private let snapshotStore: WidgetSnapshotStore
    private var changes: AnyCancellable?
    private var lastSnapshot: WidgetSnapshot?

    init?(app: AppStore) {
        // Preview and test profiles must never replace a person's live widget.
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains("--demo"), !arguments.contains("--data-directory"),
              let group = Bundle.main.object(forInfoDictionaryKey: "PulseAppGroupIdentifier") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        self.app = app
        snapshotStore = WidgetSnapshotStore(directoryURL: container.appendingPathComponent("Widget", isDirectory: true))
        let publishers: [AnyPublisher<Void, Never>] = [
            app.$connections.map { _ in () }.eraseToAnyPublisher(),
            app.$snapshots.map { _ in () }.eraseToAnyPublisher(),
            app.$metricVisibilities.map { _ in () }.eraseToAnyPublisher(),
            app.$selectedRange.map { _ in () }.eraseToAnyPublisher(),
            app.$errors.map { _ in () }.eraseToAnyPublisher()
        ]
        changes = Publishers.MergeMany(publishers)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.publish() }
    }

    private func publish() {
        guard let app else { return }
        var snapshot = WidgetSnapshotBuilder.make(connections: app.connections, snapshots: app.snapshots,
                                                  visibility: app.metricVisibilities, defaultRange: app.selectedRange,
                                                  errors: Set(app.errors.keys))
        // A failed refresh with unchanged data should not spend another reload.
        if let lastSnapshot {
            snapshot.generatedAt = lastSnapshot.generatedAt
            guard snapshot != lastSnapshot else { return }
            snapshot.generatedAt = Date()
        }
        do {
            try snapshotStore.save(snapshot)
            lastSnapshot = snapshot
            WidgetCenter.shared.reloadTimelines(ofKind: "PulseProject")
            WidgetCenter.shared.reloadTimelines(ofKind: "PulseOverview")
        } catch {
            // A widget cache failure must not interrupt source collection.
            NSLog("Pulse couldn’t update its widget snapshot: %@", error.localizedDescription)
        }
    }
}
