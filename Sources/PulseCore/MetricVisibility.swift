import Foundation

/// Local presentation choices. These never change a source's collected metrics
/// or its notification observations.
public struct MetricVisibility: Codable, Equatable, Sendable {
    public var hiddenMetricIDs: Set<UUID>
    public var headlineMetricIDs: [UUID]?
    public var detailMetricIDs: [UUID]?
    public var visibleBreakdownIDs: [String]?

    public init(hiddenMetricIDs: Set<UUID> = [], headlineMetricIDs: [UUID]? = nil,
                detailMetricIDs: [UUID]? = nil, visibleBreakdownIDs: [String]? = nil) {
        self.hiddenMetricIDs = hiddenMetricIDs
        self.headlineMetricIDs = headlineMetricIDs
        self.detailMetricIDs = detailMetricIDs
        self.visibleBreakdownIDs = visibleBreakdownIDs
    }

    public func isVisible(_ id: UUID) -> Bool {
        !hiddenMetricIDs.contains(id)
    }
}

public extension ProjectSnapshot {
    var metricCatalog: [MetricValue] {
        var seen: Set<UUID> = []
        return (metrics + (details ?? [])).filter { seen.insert($0.id).inserted }
    }

    /// Apply after selecting a time range. The raw range summaries remain intact
    /// so hiding a number cannot change source availability, collection or alerts.
    func applyingVisibility(_ visibility: MetricVisibility) -> ProjectSnapshot {
        var display = self
        let catalog = metricCatalog
        let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        let visibleHeadlines: [MetricValue]
        if let selected = visibility.headlineMetricIDs {
            var seen: Set<UUID> = []
            visibleHeadlines = Array(selected.filter { seen.insert($0).inserted }.compactMap { byID[$0] }.prefix(3))
        } else {
            visibleHeadlines = Array(metrics.filter { visibility.isVisible($0.id) }.prefix(3))
        }
        // A later source edit can leave only IDs that were previously hidden.
        // Keep one current headline so the card never becomes blank.
        display.metrics = visibleHeadlines.isEmpty ? Array(metrics.prefix(1)) : visibleHeadlines
        let headlineIDs = Set(display.metrics.map(\.id))
        let drawerMetrics: [MetricValue]
        if let selected = visibility.detailMetricIDs {
            var seen: Set<UUID> = []
            drawerMetrics = Array(selected.filter { !headlineIDs.contains($0) && seen.insert($0).inserted }.compactMap { byID[$0] }.prefix(6))
        } else {
            drawerMetrics = Array((details ?? []).filter { !headlineIDs.contains($0.id) && visibility.isVisible($0.id) }.prefix(6))
        }
        display.details = drawerMetrics.isEmpty ? nil : drawerMetrics
        let groups: [MetricBreakdown]
        if let selected = visibility.visibleBreakdownIDs {
            var seen: Set<String> = []
            let byID = Dictionary((breakdowns ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            groups = Array(selected.filter { seen.insert($0).inserted }.compactMap { byID[$0] }.prefix(2))
        } else { groups = Array((breakdowns ?? []).prefix(2)) }
        display.breakdowns = groups.isEmpty ? nil : groups
        return display
    }
}
