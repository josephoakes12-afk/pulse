import AppIntents
import Foundation

enum PulseWidgetRange: String, AppEnum {
    case followPulse = "pulse", day = "24h", week = "7d", month = "30d", lifetime
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Time range")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .followPulse: "Follow Pulse", .day: "24 hours", .week: "7 days", .month: "30 days", .lifetime: "Lifetime"
    ]
    var requestedRange: String? { self == .followPulse ? nil : rawValue }
}

struct PulseProjectEntity: AppEntity {
    var id: String
    var name: String
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Project")
    static let defaultQuery = PulseProjectQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PulseProjectQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PulseProjectEntity] {
        let projects = WidgetData.snapshot()?.projects ?? []
        return identifiers.compactMap { id in
            guard UUID(uuidString: id) != nil else { return nil }
            return PulseProjectEntity(id: id, name: projects.first { $0.id.uuidString == id }?.name ?? "Unavailable")
        }
    }
    func suggestedEntities() async throws -> [PulseProjectEntity] {
        (WidgetData.snapshot()?.projects ?? []).map { PulseProjectEntity(id: $0.id.uuidString, name: $0.name) }
    }
}

struct ProjectWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Project"
    static let description = IntentDescription("A project's key numbers.")
    @Parameter(title: "Project") var project: PulseProjectEntity?
    @Parameter(title: "Time range", default: .followPulse) var range: PulseWidgetRange
}

struct OverviewWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Overview"
    static let description = IntentDescription("Your projects at a glance.")
    @Parameter(title: "Time range", default: .followPulse) var range: PulseWidgetRange
}
