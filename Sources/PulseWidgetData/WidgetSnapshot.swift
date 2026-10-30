import Foundation

/// The widget receives display numbers only, never source settings or credentials.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let supportedRangeRawValues: Set<String> = ["24h", "7d", "30d", "lifetime"]
    public static let maximumProjects = 50
    public static let maximumIconBytes = 64 * 1_024

    public var schemaVersion: Int
    public var generatedAt: Date
    public var defaultRangeRawValue: String
    public var projects: [WidgetProject]

    public init(schemaVersion: Int = WidgetSnapshot.currentSchemaVersion, generatedAt: Date = Date(),
                defaultRangeRawValue: String = "7d", projects: [WidgetProject] = []) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.defaultRangeRawValue = defaultRangeRawValue
        self.projects = projects
    }

    /// A configured project never silently changes to a different project.
    /// Explicitly chosen paused projects remain available with their cached numbers.
    public func project(id: UUID?, rangeRawValue: String? = nil) -> WidgetProject? {
        let range = rangeRawValue ?? defaultRangeRawValue
        guard Self.supportedRangeRawValues.contains(range) else { return nil }
        if let id {
            return projects.first { $0.id == id && $0.range(rawValue: range) != nil }
        }
        return projects.first { $0.enabled && $0.range(rawValue: range) != nil }
    }

    public func overview(rangeRawValue: String? = nil, limit: Int = 3) -> [WidgetProject] {
        let range = rangeRawValue ?? defaultRangeRawValue
        guard Self.supportedRangeRawValues.contains(range) else { return [] }
        return Array(projects.lazy.filter { $0.enabled && $0.range(rawValue: range) != nil }
            .prefix(max(0, min(limit, 3))))
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              generatedAt.timeIntervalSinceReferenceDate.isFinite,
              Self.supportedRangeRawValues.contains(defaultRangeRawValue),
              projects.count <= Self.maximumProjects,
              Set(projects.map(\.id)).count == projects.count else {
            throw WidgetSnapshotError.invalidSnapshot
        }
        let symbolCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.")
        for project in projects {
            guard validText(project.name, maximumBytes: 256),
                  validText(project.symbol, maximumBytes: 80),
                  project.symbol.unicodeScalars.allSatisfy({ symbolCharacters.contains($0) }),
                  project.iconImageData.map({ !$0.isEmpty && $0.count <= Self.maximumIconBytes }) ?? true,
                  project.ranges.count <= 4,
                  Set(project.ranges.map(\.rawValue)).count == project.ranges.count else {
                throw WidgetSnapshotError.invalidSnapshot
            }
            for range in project.ranges {
                guard Self.supportedRangeRawValues.contains(range.rawValue),
                      validText(range.title, maximumBytes: 80),
                      range.measuredAt.timeIntervalSinceReferenceDate.isFinite,
                      (1...3).contains(range.metrics.count),
                      Set(range.metrics.map(\.id)).count == range.metrics.count,
                      range.metrics.allSatisfy({ validText($0.label, maximumBytes: 256) && validText($0.value, maximumBytes: 256) }) else {
                    throw WidgetSnapshotError.invalidSnapshot
                }
            }
        }
    }
}

public struct WidgetProject: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var iconImageData: Data?
    public var enabled: Bool
    public var hasError: Bool
    public var ranges: [WidgetRange]

    public init(id: UUID, name: String, symbol: String, iconImageData: Data? = nil,
                enabled: Bool = true, hasError: Bool = false, ranges: [WidgetRange]) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.iconImageData = iconImageData
        self.enabled = enabled
        self.hasError = hasError
        self.ranges = ranges
    }

    public func range(rawValue: String) -> WidgetRange? {
        ranges.first { $0.rawValue == rawValue }
    }
}

public struct WidgetRange: Codable, Equatable, Sendable {
    public var rawValue: String
    public var title: String
    public var measuredAt: Date
    public var metrics: [WidgetMetric]

    public init(rawValue: String, title: String, measuredAt: Date, metrics: [WidgetMetric]) {
        self.rawValue = rawValue
        self.title = title
        self.measuredAt = measuredAt
        self.metrics = metrics
    }
}

public struct WidgetMetric: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var value: String

    public init(id: UUID, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public enum WidgetSnapshotError: LocalizedError, Equatable, Sendable {
    case invalidSnapshot
    case snapshotTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot: "The widget snapshot is not valid."
        case .snapshotTooLarge: "The widget snapshot is too large."
        }
    }
}

/// One bounded, atomic JSON file shared by the app and its widget extension.
public struct WidgetSnapshotStore: Sendable {
    public static let fileName = "widget-snapshot.json"
    public static let maximumSnapshotBytes = 2 * 1_024 * 1_024
    public let directoryURL: URL
    public var fileURL: URL { directoryURL.appendingPathComponent(Self.fileName, isDirectory: false) }

    public init(directoryURL: URL) { self.directoryURL = directoryURL }

    public func load() -> WidgetSnapshot? {
        do {
            guard try FileManager.default.attributesOfItem(atPath: directoryURL.path)[.type] as? FileAttributeType == .typeDirectory else { return nil }
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  size.intValue <= Self.maximumSnapshotBytes else { return nil }
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: Self.maximumSnapshotBytes + 1),
                  data.count <= Self.maximumSnapshotBytes else { return nil }
            let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
            try snapshot.validate()
            return snapshot
        } catch { return nil }
    }

    public func save(_ snapshot: WidgetSnapshot) throws {
        try snapshot.validate()
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= Self.maximumSnapshotBytes else { throw WidgetSnapshotError.snapshotTooLarge }
        let files = FileManager.default
        try files.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try files.attributesOfItem(atPath: directoryURL.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw WidgetSnapshotError.invalidSnapshot
        }
        // Tighten only this dedicated snapshot directory, never its ancestors.
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        try data.write(to: fileURL, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

private func validText(_ value: String, maximumBytes: Int) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= maximumBytes
}
