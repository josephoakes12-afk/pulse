import Foundation

/// The private sync boundary contains display summaries only. Local icons and
/// all source settings stay on the collecting Mac.
public struct CloudSyncSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumEncodedBytes = 128 * 1_024
    public static let maximumClockSkew: TimeInterval = 5 * 60

    public let schemaVersion: Int
    public let publisherID: UUID
    public let snapshot: WidgetSnapshot
    /// A minimal marker contains no projects and fences former collectors after
    /// the person removes their cloud copy. Older clients still read it as an
    /// empty summary belonging to another publisher.
    public let isCleared: Bool

    public init(schemaVersion: Int = CloudSyncSnapshot.currentSchemaVersion,
                publisherID: UUID, snapshot: WidgetSnapshot, isCleared: Bool = false) {
        self.schemaVersion = schemaVersion
        self.publisherID = publisherID
        var summary = snapshot
        for index in summary.projects.indices { summary.projects[index].iconImageData = nil }
        self.snapshot = summary
        self.isCleared = isCleared
    }

    public static func prepared(publisherID: UUID, snapshot: WidgetSnapshot,
                                now: Date = Date()) throws -> CloudSyncSnapshot {
        let result = CloudSyncSnapshot(publisherID: publisherID, snapshot: snapshot)
        try result.validate(now: now)
        return result
    }

    public func validate(now: Date = Date()) throws {
        _ = try encoded(now: now)
    }

    public func encoded(now: Date = Date()) throws -> Data {
        try validateContents(now: now)
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumEncodedBytes else { throw CloudSyncSnapshotError.snapshotTooLarge }
        return data
    }

    public static func decode(_ data: Data, now: Date = Date()) throws -> CloudSyncSnapshot {
        guard data.count <= Self.maximumEncodedBytes else { throw CloudSyncSnapshotError.snapshotTooLarge }
        let result = try JSONDecoder().decode(CloudSyncSnapshot.self, from: data)
        try result.validate(now: now)
        return result
    }

    /// A stale completion must not replace a newer summary or revive a deleted
    /// project. Changing the collecting Mac is a separate, explicit action.
    public func preferred(over current: CloudSyncSnapshot?, now: Date = Date()) throws -> CloudSyncSnapshot {
        try validate(now: now)
        guard let current else { return self }
        try current.validate(now: now)
        guard publisherID == current.publisherID else { throw CloudSyncSnapshotError.publisherMismatch }
        return snapshot.generatedAt > current.snapshot.generatedAt ? self : current
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        publisherID = try values.decode(UUID.self, forKey: .publisherID)
        snapshot = try values.decode(WidgetSnapshot.self, forKey: .snapshot)
        isCleared = try values.decodeIfPresent(Bool.self, forKey: .cleared) ?? false
        guard snapshot.projects.allSatisfy({ $0.iconImageData == nil }) else {
            throw CloudSyncSnapshotError.invalidSnapshot
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(publisherID, forKey: .publisherID)
        try values.encode(snapshot, forKey: .snapshot)
        if isCleared { try values.encode(true, forKey: .cleared) }
    }

    private func validateContents(now: Date) throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw CloudSyncSnapshotError.unsupportedVersion }
        try snapshot.validate()
        guard !isCleared || snapshot.projects.isEmpty else { throw CloudSyncSnapshotError.invalidSnapshot }
        guard Self.validTimestamp(now, relativeTo: now),
              Self.validTimestamp(snapshot.generatedAt, relativeTo: now),
              snapshot.projects.allSatisfy({ project in
                  project.iconImageData == nil && project.ranges.allSatisfy { range in
                      Self.validTimestamp(range.measuredAt, relativeTo: now) &&
                      range.measuredAt.timeIntervalSince(snapshot.generatedAt) <= Self.maximumClockSkew
                  }
              }) else { throw CloudSyncSnapshotError.invalidSnapshot }
    }

    private static func validTimestamp(_ date: Date, relativeTo now: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && date.timeIntervalSince1970 >= 0 &&
        date.timeIntervalSince(now) <= maximumClockSkew
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, publisherID, snapshot, cleared
    }
}

public enum CloudSyncSnapshotError: LocalizedError, Equatable, Sendable {
    case invalidSnapshot
    case unsupportedVersion
    case snapshotTooLarge
    case publisherMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot: "The iCloud summary is not valid."
        case .unsupportedVersion: "Update Pulse to read this iCloud summary."
        case .snapshotTooLarge: "The iCloud summary is too large."
        case .publisherMismatch: "Another Mac is providing the iCloud summary."
        }
    }
}
