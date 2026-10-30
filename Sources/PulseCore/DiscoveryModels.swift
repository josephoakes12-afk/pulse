import Foundation

public struct DiscoveredMetric: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let label: String
    public let previewValue: String
    public init(path: String, label: String, previewValue: String) { self.path = path; self.label = label; self.previewValue = previewValue }
}

public struct DatabaseTable: Codable, Identifiable, Equatable, Sendable {
    public var id: String { "\(schema.utf8.count):\(schema)\(name)" }
    public let schema: String
    public let name: String
    public let isView: Bool
    public init(schema: String, name: String, isView: Bool) { self.schema = schema; self.name = name; self.isView = isView }
}

public enum ProjectSetup {
    public struct ParsedAddress: Equatable, Sendable {
        public let kind: ConnectorKind
        public let endpoint: String
        public let secret: String?
        public let suggestedName: String
        public init(kind: ConnectorKind, endpoint: String, secret: String?, suggestedName: String) { self.kind = kind; self.endpoint = endpoint; self.secret = secret; self.suggestedName = suggestedName }
    }

    public static func parseAddress(_ input: String) throws -> ParsedAddress {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: input), let host = parts.host, !host.isEmpty else { throw PulseError.invalidConfiguration("Paste a complete API URL or PostgreSQL connection string.") }
        let kind: ConnectorKind = ["postgres", "postgresql"].contains(parts.scheme?.lowercased() ?? "") ? .postgres : .http
        var secret: String?
        if kind == .postgres {
            secret = parts.password
            parts.password = nil
        } else {
            guard parts.user == nil, parts.password == nil else { throw PulseError.invalidConfiguration("Use a URL without login details. Add the token separately.") }
        }
        guard let endpoint = parts.string else { throw PulseError.invalidConfiguration("This connection address couldn’t be read.") }
        var check = ProjectConnection(name: "New project", kind: kind, endpoint: endpoint, query: kind == .postgres ? "SELECT 1 AS total" : "", metrics: [MetricDefinition(label: "Total", path: "total")])
        check.authHeader = "Authorization"
        try ConnectorValidation.validate(check)
        let base = host == "localhost" || host == "127.0.0.1" || host == "::1" ? "Local project" : host.replacingOccurrences(of: "www.", with: "").split(separator: ".").first.map(String.init) ?? "New project"
        return ParsedAddress(kind: kind, endpoint: endpoint, secret: secret, suggestedName: base == "Local project" ? base : friendlyLabel(base))
    }

    public static func friendlyLabel(_ key: String) -> String {
        var label = key.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        label = label.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
        label = label.replacingOccurrences(of: "(?i)(?:\\s*)(7|30|90)d$", with: " · $1d", options: .regularExpression)
        return label.prefix(1).uppercased() + label.dropFirst()
    }
}
