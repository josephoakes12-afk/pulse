import Foundation

public enum MetricTimeRange: String, Codable, CaseIterable, Sendable {
    case last24Hours = "24h", last7Days = "7d", last30Days = "30d", lifetime
    public var shortTitle: String {
        switch self { case .last24Hours: "24h"; case .last7Days: "7d"; case .last30Days: "30d"; case .lifetime: "All time" }
    }
    public var title: String {
        switch self { case .last24Hours: "Last 24 hours"; case .last7Days: "Last 7 days"; case .last30Days: "Last 30 days"; case .lifetime: "Lifetime" }
    }
}

public struct MetricRangeSnapshot: Codable, Equatable, Sendable {
    public var metrics: [MetricValue]
    public var coverage: String?
    public var details: [MetricValue]?
    public var breakdowns: [MetricBreakdown]?
    public init(metrics: [MetricValue], coverage: String? = nil, details: [MetricValue]? = nil, breakdowns: [MetricBreakdown]? = nil) {
        self.metrics = metrics; self.coverage = coverage; self.details = details; self.breakdowns = breakdowns
    }
}

public extension ProjectSnapshot {
    /// Availability is declared by the source, not inferred from a project's age
    /// or its first recorded event. An empty period can still be a valid range.
    var availableRanges: [MetricTimeRange] {
        guard let ranges else { return [.lifetime] }
        return MetricTimeRange.allCases.filter { ranges[$0.rawValue] != nil }
    }

    func supports(_ range: MetricTimeRange) -> Bool {
        ranges?[range.rawValue] != nil || (ranges == nil && range == .lifetime)
    }

    /// Range switching uses only already-fetched summaries and never infers a
    /// short-period count from a lifetime total. Alert observations are independent.
    func forRange(_ range: MetricTimeRange) -> ProjectSnapshot? {
        guard let variant = ranges?[range.rawValue] else { return ranges == nil && range == .lifetime ? self : nil }
        return ProjectSnapshot(projectID: projectID, metrics: variant.metrics, events: events, measuredAt: measuredAt,
                               fetchedAt: fetchedAt, coverage: variant.coverage ?? coverage, details: variant.details,
                               breakdowns: variant.breakdowns, ranges: ranges, alertObservations: alertObservations)
    }
}

public struct CounterAlertObservation: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var value: Int64
    public var unitSingular: String
    public var unitPlural: String
    public init(id: String, label: String, value: Int64, unitSingular: String, unitPlural: String) {
        self.id = id; self.label = label; self.value = value; self.unitSingular = unitSingular; self.unitPlural = unitPlural
    }
}

public struct DailyAlertObservation: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var today: Int64
    public var yesterday: Int64
    /// Calendar day at the source, rather than a rolling 24-hour window.
    public var day: String
    public init(id: String, label: String, today: Int64, yesterday: Int64, day: String) {
        self.id = id; self.label = label; self.today = today; self.yesterday = yesterday; self.day = day
    }
}

public struct AlertObservations: Codable, Equatable, Sendable {
    public var counters: [CounterAlertObservation]
    public var daily: [DailyAlertObservation]
    public init(counters: [CounterAlertObservation] = [], daily: [DailyAlertObservation] = []) {
        self.counters = counters; self.daily = daily
    }
}
