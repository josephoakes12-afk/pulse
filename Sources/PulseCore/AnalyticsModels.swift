import CryptoKit
import Foundation

public struct MetricBreakdownRow: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var value: String
    public init(id: String, label: String, value: String) { self.id = id; self.label = label; self.value = value }
}

public struct MetricBreakdown: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var rows: [MetricBreakdownRow]
    public var truncated: Bool
    public init(id: String, title: String, rows: [MetricBreakdownRow], truncated: Bool = false) { self.id = id; self.title = title; self.rows = rows; self.truncated = truncated }
}

/// Only declared, single-column foreign keys are eligible for automatic grouping.
public struct DatabaseRelationship: Codable, Equatable, Sendable {
    public var child: DatabaseTable
    public var childColumn: String
    public var parent: DatabaseTable
    public var parentColumn: String
    public var parentLabelColumn: String?
    public init(child: DatabaseTable, childColumn: String, parent: DatabaseTable, parentColumn: String, parentLabelColumn: String? = nil) {
        self.child = child; self.childColumn = childColumn; self.parent = parent; self.parentColumn = parentColumn; self.parentLabelColumn = parentLabelColumn
    }
}

public struct DatabaseAnalyticsPlan: Codable, Equatable, Sendable {
    public var version: Int
    public var relationships: [DatabaseRelationship]
    public var columns: [DatabaseColumn]?
    public init(relationships: [DatabaseRelationship], version: Int = 1, columns: [DatabaseColumn]? = nil) {
        self.version = version; self.relationships = relationships; self.columns = columns
    }
}

/// Structural evidence only. Enum labels come from pg_enum, not source records.
public struct DatabaseColumn: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case boolean, enumeration, timestamp }
    public var table: DatabaseTable
    public var name: String
    public var kind: Kind
    public var enumValues: [String]
    public init(table: DatabaseTable, name: String, kind: Kind, enumValues: [String] = []) {
        self.table = table; self.name = name; self.kind = kind; self.enumValues = enumValues
    }
}

public enum MetricIdentity {
    public static func uuid(projectID: UUID, path: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data((projectID.uuidString + ":" + path).utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
