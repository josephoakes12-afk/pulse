import Foundation

public enum ConnectorKind: String, Codable, CaseIterable, Sendable {
    case http, postgres, supabase
    public var title: String {
        switch self { case .http: "HTTP / JSON"; case .postgres: "PostgreSQL"; case .supabase: "Supabase" }
    }
}

public struct MetricDefinition: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var path: String
    public init(id: UUID = UUID(), label: String, path: String) { self.id = id; self.label = label; self.path = path }
}

public struct ProjectConnection: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String
    /// A normalized, local thumbnail. Source file paths are never retained.
    public var iconImageData: Data?
    public var kind: ConnectorKind
    public var endpoint: String
    public var query: String
    public var authHeader: String
    /// A non-secret generation marker lets storage reject responses for replaced credentials.
    public var credentialVersion: UUID
    public var metrics: [MetricDefinition]
    public var intervalSeconds: Int
    public var notificationsEnabled: Bool
    public var enabled: Bool
    public var link: String
    public var autoStats: DatabaseAnalyticsPlan?
    public var sourceTables: [DatabaseTable]?
    public init(id: UUID = UUID(), name: String, symbol: String = "square.stack.3d.up", iconImageData: Data? = nil, kind: ConnectorKind = .http, endpoint: String = "", query: String = "", authHeader: String = "Authorization", credentialVersion: UUID = UUID(), metrics: [MetricDefinition] = [], intervalSeconds: Int = 300, notificationsEnabled: Bool = false, enabled: Bool = true, link: String = "", autoStats: DatabaseAnalyticsPlan? = nil, sourceTables: [DatabaseTable]? = nil) {
        self.id = id; self.name = name; self.symbol = symbol; self.iconImageData = iconImageData; self.kind = kind; self.endpoint = endpoint; self.query = query; self.authHeader = authHeader; self.credentialVersion = credentialVersion; self.metrics = metrics; self.intervalSeconds = intervalSeconds; self.notificationsEnabled = notificationsEnabled; self.enabled = enabled; self.link = link; self.autoStats = autoStats; self.sourceTables = sourceTables
    }

    /// Icon edits do not invalidate an in-flight collection. All other settings,
    /// including credentials, metric mappings and alert choices, must still match.
    public func hasSameCollectionConfiguration(as other: ProjectConnection) -> Bool {
        var normalized = other
        normalized.symbol = symbol
        normalized.iconImageData = iconImageData
        return self == normalized
    }
}

public struct MetricValue: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var value: String
    public init(id: UUID, label: String, value: String) { self.id = id; self.label = label; self.value = value }
}

public struct PulseEvent: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var occurredAt: Date
    public var url: String?
    public init(id: String, title: String, occurredAt: Date, url: String? = nil) { self.id = id; self.title = title; self.occurredAt = occurredAt; self.url = url }
}

public struct ProjectSnapshot: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var metrics: [MetricValue]
    public var events: [PulseEvent]
    public var measuredAt: Date
    public var fetchedAt: Date
    public var coverage: String?
    public var details: [MetricValue]?
    public var breakdowns: [MetricBreakdown]?
    public var ranges: [String: MetricRangeSnapshot]?
    public var alertObservations: AlertObservations?
    public init(projectID: UUID, metrics: [MetricValue], events: [PulseEvent] = [], measuredAt: Date = Date(), fetchedAt: Date = Date(), coverage: String? = nil, details: [MetricValue]? = nil, breakdowns: [MetricBreakdown]? = nil, ranges: [String: MetricRangeSnapshot]? = nil, alertObservations: AlertObservations? = nil) {
        self.projectID = projectID; self.metrics = metrics; self.events = events; self.measuredAt = measuredAt; self.fetchedAt = fetchedAt; self.coverage = coverage; self.details = details; self.breakdowns = breakdowns; self.ranges = ranges; self.alertObservations = alertObservations
    }
}

public protocol SummaryConnector: Sendable {
    func collect(connection: ProjectConnection, secret: String?) async throws -> ProjectSnapshot
}

public enum PulseError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String), response(String), storage(String), credential(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let text), .response(let text), .storage(let text), .credential(let text): text
        }
    }
}

public enum DemoData {
    public static let projects: [ProjectConnection] = [
        ProjectConnection(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Booking Studio", symbol: "calendar", metrics: [MetricDefinition(label: "businesses", path: "businesses"), MetricDefinition(label: "bookings · 7d", path: "bookings")], link: "https://supabase.com/dashboard"),
        ProjectConnection(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Playroom", symbol: "gamecontroller", metrics: [MetricDefinition(label: "players · 7d", path: "players"), MetricDefinition(label: "games · 7d", path: "games")], link: "https://console.neon.tech/"),
        ProjectConnection(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "The Daily", symbol: "newspaper", metrics: [MetricDefinition(label: "readers · 7d", path: "readers"), MetricDefinition(label: "signed in · 7d", path: "signedIn")], link: "https://supabase.com/dashboard")
    ]
    public static func snapshots(now: Date = Date()) -> [ProjectSnapshot] {
        zip(projects, [["12", "38"], ["46", "15"], ["210", "64"]]).enumerated().map { index, pair in
            let (project, values) = pair
            let extra = [[("Active · 7d", "5"), ("Bookings / business · 7d", "3.2")], [("Players today", "18"), ("Returning · 7d", "12")], [("Reads · 7d", "890"), ("Accounts", "126")]][index]
            let details = extra.enumerated().map { offset, item in MetricValue(id: MetricIdentity.uuid(projectID: project.id, path: "demo.\(offset)"), label: item.0, value: item.1) }
            let breakdowns = index == 0 ? [MetricBreakdown(id: "demo-bookings", title: "Bookings by business · 7d", rows: [("Oak Studio", "12"), ("Maple & Co", "9"), ("Cedar Rooms", "8"), ("Juniper", "6"), ("Birch Studio", "3")].enumerated().map { MetricBreakdownRow(id: "demo-\($0.offset)", label: $0.element.0, value: $0.element.1) })] : []
            return ProjectSnapshot(projectID: project.id, metrics: zip(project.metrics, values).map { MetricValue(id: $0.id, label: $0.label, value: $1) }, measuredAt: now, fetchedAt: now, coverage: "Example data", details: details, breakdowns: breakdowns)
        }
    }
}
