import Foundation

/// Local presentation choices. These never change a source's collected metrics
/// or its notification observations.
public struct MetricVisibility: Codable, Equatable, Sendable {
    public var hiddenMetricIDs: Set<UUID>

    public init(hiddenMetricIDs: Set<UUID> = []) {
        self.hiddenMetricIDs = hiddenMetricIDs
    }

    public func isVisible(_ id: UUID) -> Bool {
        !hiddenMetricIDs.contains(id)
    }
}

public extension ProjectSnapshot {
    /// Apply after selecting a time range. The raw range summaries remain intact
    /// so hiding a number cannot change source availability, collection or alerts.
    func applyingVisibility(_ visibility: MetricVisibility) -> ProjectSnapshot {
        guard !visibility.hiddenMetricIDs.isEmpty else { return self }
        var display = self
        let visibleHeadlines = metrics.filter { visibility.isVisible($0.id) }
        // A later source edit can leave only IDs that were previously hidden.
        // Keep one current headline so the card never becomes blank.
        display.metrics = visibleHeadlines.isEmpty ? Array(metrics.prefix(1)) : visibleHeadlines
        if let details {
            let visibleDetails = details.filter { visibility.isVisible($0.id) }
            display.details = visibleDetails.isEmpty ? nil : visibleDetails
        }
        return display
    }
}
