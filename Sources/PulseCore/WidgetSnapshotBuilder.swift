import Foundation
import PulseWidgetData

/// Only the aggregate numbers needed by WidgetKit cross this boundary.
public enum WidgetSnapshotBuilder {
    public static func make(connections: [ProjectConnection], snapshots: [UUID: ProjectSnapshot],
                            visibility: [UUID: MetricVisibility], defaultRange: MetricTimeRange,
                            errors: Set<UUID> = [], now: Date = Date()) -> WidgetSnapshot {
        var iconBudget = 512 * 1024
        let projects = connections.prefix(50).map { project in
            let source = snapshots[project.id]
            let ranges = MetricTimeRange.allCases.compactMap { range -> WidgetRange? in
                guard let snapshot = source?.forRange(range) else { return nil }
                let display = snapshot.applyingVisibility(visibility[project.id] ?? MetricVisibility())
                guard !display.metrics.isEmpty else { return nil }
                return WidgetRange(rawValue: range.rawValue, title: range.shortTitle,
                                   measuredAt: snapshot.measuredAt,
                                   metrics: display.metrics.prefix(3).map { WidgetMetric(id: $0.id, label: text($0.label), value: text($0.value)) })
            }
            let image = project.iconImageData.flatMap { $0.count <= min(64 * 1024, iconBudget) ? $0 : nil }
            iconBudget -= image?.count ?? 0
            return WidgetProject(id: project.id, name: text(project.name), symbol: project.symbol, iconImageData: image,
                                 enabled: project.enabled, hasError: errors.contains(project.id), ranges: ranges)
        }
        return WidgetSnapshot(generatedAt: now, defaultRangeRawValue: defaultRange.rawValue, projects: projects)
    }

    private static func text(_ value: String) -> String {
        var result = String(value.prefix(60))
        while result.utf8.count > 256 { result.removeLast() }
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : result
    }
}
