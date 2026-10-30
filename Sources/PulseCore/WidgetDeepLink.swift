import Foundation

public struct WidgetDeepLink: Equatable, Sendable {
    public var projectID: UUID?
    public var range: MetricTimeRange?

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "pulse-metrics", components.user == nil,
              components.password == nil, components.port == nil else { return nil }
        let rangeItems = (components.queryItems ?? []).filter { $0.name == "range" }
        guard rangeItems.count <= 1 else { return nil }
        if let item = rangeItems.first {
            guard let value = item.value, let range = MetricTimeRange(rawValue: value) else { return nil }
            self.range = range
        }
        switch components.host {
        case "open":
            guard components.path.isEmpty || components.path == "/" else { return nil }
        case "project":
            let segments = components.path.split(separator: "/")
            guard segments.count == 1, let id = UUID(uuidString: String(segments[0])) else { return nil }
            projectID = id
        default: return nil
        }
    }
}
