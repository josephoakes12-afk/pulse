import PulseCore

/// Explicitly fictional periods for the labelled first-launch preview.
enum DemoMetricRanges {
    static func snapshots() -> [ProjectSnapshot] {
        let values: [[[String]]] = [
            [["2", "8"], ["12", "38"], ["18", "164"], ["42", "902"]],
            [["18", "3"], ["46", "15"], ["128", "67"], ["320", "214"]],
            [["32", "8"], ["210", "64"], ["904", "126"], ["3,420", "280"]]
        ]
        return DemoData.snapshots().enumerated().map { index, base in
            var snapshot = base
            snapshot.ranges = Dictionary(uniqueKeysWithValues: MetricTimeRange.allCases.enumerated().map { offset, range in
                let metrics = base.metrics.enumerated().map { number, metric in
                    MetricValue(id: metric.id, label: metric.label.replacingOccurrences(of: " · 7d", with: ""), value: values[index][offset][number])
                }
                return (range.rawValue, MetricRangeSnapshot(metrics: metrics, coverage: "Example data", details: range == .last7Days ? base.details : nil, breakdowns: range == .last7Days ? base.breakdowns : nil))
            })
            return snapshot
        }
    }
}
