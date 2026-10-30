import Foundation
import CSQLite

/// Small, private on-disk cache. Source data remains authoritative.
public actor LocalStore {
    private let database: SQLiteDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let eventLimit = 1_000
    private static let catchUpSeconds: TimeInterval = 7 * 24 * 60 * 60

    public init(databaseURL: URL) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Only tighten the app's immediate data directory, never its ancestors.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        database = try SQLiteDatabase(url: databaseURL)
        try database.execute("PRAGMA foreign_keys = ON")
        try database.execute("PRAGMA journal_mode = DELETE")
        try database.execute("PRAGMA secure_delete = ON")
        try database.execute("PRAGMA busy_timeout = 3000")
        let version = try database.rows("PRAGMA user_version").first?["user_version"]?.integer ?? 0
        guard version <= 3 else { throw PulseError.storage("This cache was created by a newer version of Pulse.") }
        try database.transaction {
            try database.execute("CREATE TABLE IF NOT EXISTS connections (id TEXT PRIMARY KEY, position INTEGER NOT NULL, payload TEXT NOT NULL)")
            try database.execute("CREATE TABLE IF NOT EXISTS snapshots (project_id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
            try database.execute("CREATE TABLE IF NOT EXISTS project_state (project_id TEXT PRIMARY KEY, initialized INTEGER NOT NULL DEFAULT 0, pruned_before REAL NOT NULL DEFAULT 0)")
            try database.execute("CREATE TABLE IF NOT EXISTS events (project_id TEXT NOT NULL, event_id TEXT NOT NULL, occurred_at REAL NOT NULL, payload TEXT NOT NULL, pending INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (project_id, event_id))")
            try database.execute("CREATE INDEX IF NOT EXISTS events_recent ON events (project_id, occurred_at DESC)")
            try database.execute("CREATE TABLE IF NOT EXISTS alert_state (project_id TEXT NOT NULL, observation_key TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (project_id, observation_key))")
            try database.execute("CREATE TABLE IF NOT EXISTS presentation_state (project_id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
            try database.execute("PRAGMA user_version = 3")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
    }

    public func loadConnections() throws -> [ProjectConnection] {
        try database.rows("SELECT payload FROM connections ORDER BY position, id").map {
            try decode(ProjectConnection.self, row: $0)
        }
    }

    public func saveConnections(_ connections: [ProjectConnection]) throws {
        guard Set(connections.map(\.id)).count == connections.count else {
            throw PulseError.storage("A connection is listed more than once.")
        }
        for connection in connections {
            try ProjectIconLimits.validate(symbol: connection.symbol, imageData: connection.iconImageData)
        }
        try database.transaction {
            let previousConnections = try database.rows("SELECT payload FROM connections").map { try decode(ProjectConnection.self, row: $0) }
            let previous = previousConnections.map { $0.id.uuidString }
            let previousByID = Dictionary(uniqueKeysWithValues: previousConnections.map { ($0.id, $0) })
            let retained = Set(connections.map { $0.id.uuidString })
            for project in previous where !retained.contains(project) { try removeProjectRows(project) }
            try database.execute("DELETE FROM connections")
            for (index, connection) in connections.enumerated() {
                if let old = previousByID[connection.id], sourceChanged(from: old, to: connection) {
                    // A different source (or account at the same URL) gets its own
                    // quiet baseline, rather than announcing its historical events.
                    try removeCachedProjectRows(connection.id.uuidString)
                }
                try database.execute("INSERT INTO connections (id, position, payload) VALUES (?, ?, ?)",
                                     [.text(connection.id.uuidString), .integer(Int64(index)), .text(try json(connection))])
                if !connection.notificationsEnabled {
                    try database.execute("UPDATE events SET pending = 0 WHERE project_id = ?", [.text(connection.id.uuidString)])
                }
            }
        }
    }

    /// Edits only the current icon, even if source settings changed while its picker
    /// was open. A removed connection is never recreated by an icon edit.
    @discardableResult
    public func updateIcon(projectID: UUID, symbol: String, imageData: Data?) throws -> ProjectConnection {
        try ProjectIconLimits.validate(symbol: symbol, imageData: imageData)
        var updated: ProjectConnection?
        try database.transaction {
            guard let row = try database.rows("SELECT payload FROM connections WHERE id = ?", [.text(projectID.uuidString)]).first else {
                throw PulseError.invalidConfiguration("This connection has been removed.")
            }
            var connection = try decode(ProjectConnection.self, row: row)
            connection.symbol = symbol
            connection.iconImageData = imageData
            try database.execute("UPDATE connections SET payload = ? WHERE id = ?",
                                 [.text(try json(connection)), .text(projectID.uuidString)])
            updated = connection
        }
        guard let updated else { throw PulseError.storage("Could not update this connection’s icon.") }
        return updated
    }

    public func loadSnapshots() throws -> [ProjectSnapshot] {
        try database.rows("SELECT payload FROM snapshots ORDER BY project_id").map {
            try decode(ProjectSnapshot.self, row: $0)
        }
    }

    public func loadMetricVisibility() throws -> [UUID: MetricVisibility] {
        var result: [UUID: MetricVisibility] = [:]
        for row in try database.rows("SELECT project_id, payload FROM presentation_state") {
            guard let identifier = row["project_id"]?.text, let projectID = UUID(uuidString: identifier) else {
                throw PulseError.storage("The local cache contains an unreadable entry.")
            }
            result[projectID] = try decode(MetricVisibility.self, row: row)
        }
        return result
    }

    public func metricVisibility(projectID: UUID) throws -> MetricVisibility {
        guard let row = try database.rows("SELECT payload FROM presentation_state WHERE project_id = ?",
                                          [.text(projectID.uuidString)]).first else { return MetricVisibility() }
        return try decode(MetricVisibility.self, row: row)
    }

    /// Presentation writes are independent of connection configuration and never
    /// invalidate an in-flight collection or its quiet notification baseline.
    public func saveMetricVisibility(_ visibility: MetricVisibility, projectID: UUID) throws {
        try database.transaction {
            guard try database.rows("SELECT id FROM connections WHERE id = ?", [.text(projectID.uuidString)]).first != nil else {
                throw PulseError.invalidConfiguration("This connection has been removed.")
            }
            if visibility.hiddenMetricIDs.isEmpty {
                try database.execute("DELETE FROM presentation_state WHERE project_id = ?", [.text(projectID.uuidString)])
            } else {
                try database.execute("INSERT INTO presentation_state (project_id, payload) VALUES (?, ?) ON CONFLICT(project_id) DO UPDATE SET payload = excluded.payload",
                                     [.text(projectID.uuidString), .text(try json(visibility))])
            }
        }
    }

    public func saveSnapshot(_ snapshot: ProjectSnapshot) throws {
        try persistSnapshot(snapshot)
    }

    /// A first successful fetch establishes the baseline without announcing old events.
    /// Pending events survive restart until the notification transport accepts them.
    @discardableResult
    public func acceptSnapshot(_ snapshot: ProjectSnapshot, notificationsEnabled: Bool,
                               expectedConnection: ProjectConnection? = nil) throws -> [PulseEvent] {
        let project = snapshot.projectID.uuidString
        var accepted = false
        let allowNotifications = notificationsEnabled && (expectedConnection?.notificationsEnabled ?? true)
        try database.transaction {
            if let expectedConnection {
                // A network response may finish after the user edits or removes a
                // connection. Verify the persisted configuration under this same
                // write transaction so stale work cannot recreate deleted rows.
                guard expectedConnection.id == snapshot.projectID, expectedConnection.enabled,
                      let row = try database.rows("SELECT payload FROM connections WHERE id = ?", [.text(project)]).first,
                      try decode(ProjectConnection.self, row: row).hasSameCollectionConfiguration(as: expectedConnection) else { return }
            }
            accepted = true
            try persistSnapshot(snapshot)
            let state = try database.rows("SELECT initialized, pruned_before FROM project_state WHERE project_id = ?", [.text(project)]).first
            let initialized = state?["initialized"]?.integer == 1
            let prunedBefore = state?["pruned_before"]?.real ?? 0
            if !allowNotifications {
                try database.execute("UPDATE events SET pending = 0 WHERE project_id = ?", [.text(project)])
            }
            var collectionEvents = snapshot.events
            if let observations = snapshot.alertObservations {
                let oldRows = try database.rows("SELECT observation_key, payload FROM alert_state WHERE project_id = ?", [.text(project)])
                var oldStates: [String: NativeAlertState] = [:]
                for row in oldRows {
                    if let key = row["observation_key"]?.text { oldStates[key] = try decode(NativeAlertState.self, row: row) }
                }
                let evaluation = NativeAlertEvaluator.evaluate(observations, previous: oldStates, initialized: initialized,
                                                               enabled: allowNotifications, measuredAt: snapshot.measuredAt)
                try database.execute("DELETE FROM alert_state WHERE project_id = ?", [.text(project)])
                for (key, value) in evaluation.states {
                    try database.execute("INSERT INTO alert_state (project_id, observation_key, payload) VALUES (?, ?, ?)",
                                         [.text(project), .text(key), .text(try json(value))])
                }
                if let title = NativeAlertEvaluator.title(evaluation.messages) {
                    collectionEvents.append(PulseEvent(id: "pulse:change:" + UUID().uuidString, title: title, occurredAt: snapshot.fetchedAt))
                }
            }
            let oldestAllowed = max(prunedBefore, snapshot.fetchedAt.timeIntervalSince1970 - Self.catchUpSeconds)
            for event in collectionEvents where !event.id.isEmpty && !event.title.isEmpty {
                let timestamp = event.occurredAt.timeIntervalSince1970
                let eligible = initialized && allowNotifications && timestamp > oldestAllowed
                    && timestamp <= snapshot.fetchedAt.timeIntervalSince1970 + 300
                // Do not update pending on conflicts: a delivered or suppressed event stays so.
                try database.execute("INSERT OR IGNORE INTO events (project_id, event_id, occurred_at, payload, pending) VALUES (?, ?, ?, ?, ?)",
                                     [.text(project), .text(event.id), .real(timestamp), .text(try json(event)), .integer(eligible ? 1 : 0)])
            }
            try database.execute("INSERT INTO project_state (project_id, initialized, pruned_before) VALUES (?, 1, ?) ON CONFLICT(project_id) DO UPDATE SET initialized = 1",
                                 [.text(project), .real(prunedBefore)])
            try pruneEvents(project)
        }
        return accepted && allowNotifications ? try pendingNotifications(projectID: snapshot.projectID) : []
    }

    public func markNotified(projectID: UUID, eventID: String) throws {
        try database.execute("UPDATE events SET pending = 0 WHERE project_id = ? AND event_id = ?",
                             [.text(projectID.uuidString), .text(eventID)])
    }

    public func pendingNotifications(projectID: UUID) throws -> [PulseEvent] {
        // A transport retry is bounded too; waking after weeks away must not replay
        // a backlog of notifications that stopped being useful.
        try database.execute("UPDATE events SET pending = 0 WHERE project_id = ? AND occurred_at <= ?",
                             [.text(projectID.uuidString), .real(Date().timeIntervalSince1970 - Self.catchUpSeconds)])
        return try database.rows("SELECT payload FROM events WHERE project_id = ? AND pending = 1 ORDER BY occurred_at, event_id LIMIT 100",
                                 [.text(projectID.uuidString)]).map { try decode(PulseEvent.self, row: $0) }
    }

    public func eventsForDisplay(projectID: UUID? = nil, limit: Int = 20) throws -> [PulseEvent] {
        let boundedLimit = min(max(limit, 1), 100)
        if let projectID {
            return try database.rows("SELECT payload FROM events WHERE project_id = ? ORDER BY occurred_at DESC, event_id LIMIT ?",
                                     [.text(projectID.uuidString), .integer(Int64(boundedLimit))]).map { try decode(PulseEvent.self, row: $0) }
        }
        return try database.rows("SELECT payload FROM events ORDER BY occurred_at DESC, project_id, event_id LIMIT ?",
                                 [.integer(Int64(boundedLimit))]).map { try decode(PulseEvent.self, row: $0) }
    }

    public func removeProject(_ projectID: UUID) throws {
        try database.transaction { try removeProjectRows(projectID.uuidString) }
    }

    private func removeProjectRows(_ id: String) throws {
        try database.execute("DELETE FROM connections WHERE id = ?", [.text(id)])
        try database.execute("DELETE FROM presentation_state WHERE project_id = ?", [.text(id)])
        try removeCachedProjectRows(id)
    }

    private func removeCachedProjectRows(_ id: String) throws {
        for table in ["snapshots", "project_state", "events", "alert_state"] {
            try database.execute("DELETE FROM \(table) WHERE project_id = ?", [.text(id)])
        }
    }

    private func sourceChanged(from old: ProjectConnection, to new: ProjectConnection) -> Bool {
        old.kind != new.kind || old.endpoint != new.endpoint || old.query != new.query
            || old.authHeader != new.authHeader || old.credentialVersion != new.credentialVersion
    }

    private func persistSnapshot(_ snapshot: ProjectSnapshot) throws {
        // Events have their own bounded table; avoid retaining a second unbounded copy.
        var cached = snapshot
        cached.events = Array(snapshot.events.sorted { $0.occurredAt > $1.occurredAt }.prefix(100))
        try database.execute("INSERT INTO snapshots (project_id, payload) VALUES (?, ?) ON CONFLICT(project_id) DO UPDATE SET payload = excluded.payload",
                             [.text(snapshot.projectID.uuidString), .text(try json(cached))])
    }

    private func pruneEvents(_ project: String) throws {
        let removed = try database.rows("SELECT MAX(occurred_at) AS cutoff FROM (SELECT occurred_at FROM events WHERE project_id = ? ORDER BY occurred_at DESC, event_id LIMIT -1 OFFSET ?)",
                                       [.text(project), .integer(Int64(Self.eventLimit))]).first?["cutoff"]?.real
        guard let removed else { return }
        // Keep a cutoff after receipt deletion so old source pages cannot announce again.
        try database.execute("UPDATE project_state SET pruned_before = MAX(pruned_before, ?) WHERE project_id = ?", [.real(removed), .text(project)])
        try database.execute("DELETE FROM events WHERE project_id = ? AND event_id NOT IN (SELECT event_id FROM events WHERE project_id = ? ORDER BY occurred_at DESC, event_id LIMIT ?)",
                             [.text(project), .text(project), .integer(Int64(Self.eventLimit))])
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        guard let string = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw PulseError.storage("Could not encode the local cache.")
        }
        return string
    }

    private func decode<T: Decodable>(_ type: T.Type, row: [String: SQLValue]) throws -> T {
        guard let payload = row["payload"]?.text, let data = payload.data(using: .utf8) else {
            throw PulseError.storage("The local cache contains an unreadable entry.")
        }
        do { return try decoder.decode(type, from: data) }
        catch { throw PulseError.storage("The local cache contains an unreadable entry.") }
    }
}

private enum SQLValue {
    case text(String), integer(Int64), real(Double), null
    var text: String? { if case .text(let value) = self { value } else { nil } }
    var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
    var real: Double? {
        switch self { case .real(let value): value; case .integer(let value): Double(value); default: nil }
    }
}

/// The owning actor serializes access; the helper also permits safe cleanup in deinit.
private final class SQLiteDatabase: @unchecked Sendable {
    private let handle: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw PulseError.storage("Could not open Pulse’s local cache.")
        }
        handle = database
    }

    deinit { sqlite3_close(handle) }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw PulseError.storage("Could not save Pulse’s local cache.") }
    }

    func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [[String: SQLValue]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [[String: SQLValue]] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            var row: [String: SQLValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                guard let name = sqlite3_column_name(statement, index) else { continue }
                let key = String(cString: name)
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[key] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[key] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, index) { row[key] = .text(String(cString: text)) }
                default: row[key] = .null
                }
            }
            rows.append(row)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw PulseError.storage("Could not read Pulse’s local cache.") }
        return rows
    }

    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw PulseError.storage("Could not prepare Pulse’s local cache.")
        }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .text(let value): result = sqlite3_bind_text(statement, position, value, -1, transient)
            case .integer(let value): result = sqlite3_bind_int64(statement, position, value)
            case .real(let value): result = sqlite3_bind_double(statement, position, value)
            case .null: result = sqlite3_bind_null(statement, position)
            }
            guard result == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw PulseError.storage("Could not bind Pulse’s local cache.")
            }
        }
        return statement
    }
}
