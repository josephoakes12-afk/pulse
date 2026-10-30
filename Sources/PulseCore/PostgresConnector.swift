import Foundation
import PostgresNIO
import NIOSSL
import Logging

/// Runs one bounded summary query in a read-only PostgreSQL transaction.
/// Passwords are supplied separately by the Keychain and never put in the URL.
public struct PostgresConnector: SummaryConnector {
    public init() {}

    public func collect(connection: ProjectConnection, secret: String?) async throws -> ProjectSnapshot {
        try ConnectorValidation.validate(connection)
        return try await withReadOnlyConnection(connection: connection, secret: secret) { database, logger in
            if connection.autoStats != nil, let enriched = try? Self.queryWithAnalytics(connection) {
                try await database.query("SAVEPOINT pulse_automatic_stats", logger: logger)
                do {
                    let snapshot = try await Self.readSnapshot(query: enriched, connection: connection, database: database, logger: logger)
                    try await database.query("RELEASE SAVEPOINT pulse_automatic_stats", logger: logger)
                    return snapshot
                } catch is CancellationError { throw CancellationError() }
                catch {
                    // Automatic extras are optional. A renamed column or changed
                    // permission must not take the headline counters down too.
                    try await database.query("ROLLBACK TO SAVEPOINT pulse_automatic_stats", logger: logger)
                }
            }
            return try await Self.readSnapshot(query: connection.query, connection: connection, database: database, logger: logger)
        }
    }

    private static func readSnapshot(query: String, connection: ProjectConnection, database: PostgresConnection, logger: Logger) async throws -> ProjectSnapshot {
        // The subquery prevents transaction commands and bounds the result to two
        // rows so a mistakenly broad SELECT cannot download a table.
        let sql = "SELECT row_to_json(pulse_summary)::text AS pulse_json FROM (\(query)) AS pulse_summary LIMIT 2"
        let rows = try await database.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        var payloads: [String] = []
        for try await payload in rows.decode(String.self) { payloads.append(payload) }
        guard payloads.count == 1, let data = payloads.first?.data(using: .utf8) else { throw PulseError.response("The query must return exactly one summary row.") }
        return try HTTPConnector.snapshot(data: data, connection: connection)
    }

    /// Discovers only schema metadata visible to the supplied read-only role.
    /// The first 100 are shown in a stable order; actual source records are never loaded.
    public func discoverTables(connection: ProjectConnection, secret: String?) async throws -> [DatabaseTable] {
        guard connection.kind == .postgres else { throw PulseError.invalidConfiguration("Choose a PostgreSQL connection.") }
        var check = connection
        check.query = "SELECT 1 AS total"
        check.metrics = [MetricDefinition(label: "Total", path: "total")]
        try ConnectorValidation.validate(check)
        return try await withReadOnlyConnection(connection: check, secret: secret) { database, logger in
            let rows = try await database.query("""
                SELECT n.nspname::text, c.relname::text, (c.relkind IN ('v', 'm')) AS is_view
                FROM pg_catalog.pg_class c
                JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relkind IN ('r', 'p', 'v', 'm')
                  AND n.nspname <> 'information_schema'
                  AND n.nspname NOT LIKE 'pg\\_%' ESCAPE '\\'
                  AND pg_catalog.has_schema_privilege(n.oid, 'USAGE')
                  AND pg_catalog.has_table_privilege(c.oid, 'SELECT')
                ORDER BY CASE WHEN n.nspname = 'reporting' THEN 0 WHEN n.nspname = 'public' THEN 1 ELSE 2 END,
                         CASE WHEN c.relkind IN ('v', 'm') THEN 0 ELSE 1 END,
                         n.nspname, c.relname
                LIMIT 100
                """, logger: logger)
            var tables: [DatabaseTable] = []
            for try await (schema, name, isView) in rows.decode((String, String, Bool).self) {
                tables.append(DatabaseTable(schema: schema, name: name, isView: isView))
            }
            guard !tables.isEmpty else { throw PulseError.response("No readable tables or views were found. Check this account’s read permissions.") }
            return tables
        }
    }

    /// Returns declared, validated foreign keys among the provided readable tables.
    /// Metadata is bounded and contains no user records or authentication secrets.
    public func discoverRelationships(connection: ProjectConnection, secret: String?, tables: [DatabaseTable]) async throws -> [DatabaseRelationship] {
        guard connection.kind == .postgres else { throw PulseError.invalidConfiguration("Choose a PostgreSQL connection.") }
        guard !tables.isEmpty else { return [] }
        guard tables.count <= 100 else { throw PulseError.invalidConfiguration("Choose at most 100 tables to inspect.") }
        let identities = try tables.map { table -> String in
            _ = try DatabaseAnalytics.identifier(table.schema)
            _ = try DatabaseAnalytics.identifier(table.name)
            return "(" + DatabaseAnalytics.literal(table.schema) + ", " + DatabaseAnalytics.literal(table.name) + ")"
        }.joined(separator: ", ")
        var check = connection
        check.query = "SELECT 1 AS total"
        check.metrics = [MetricDefinition(label: "Total", path: "total")]
        try ConnectorValidation.validate(check)
        return try await withReadOnlyConnection(connection: check, secret: secret) { database, logger in
            let query = """
                SELECT json_build_object(
                    'child', json_build_object('schema', cn.nspname, 'name', child.relname, 'isView', false),
                    'childColumn', ca.attname,
                    'parent', json_build_object('schema', pn.nspname, 'name', parent.relname, 'isView', false),
                    'parentColumn', pa.attname,
                    'parentLabelColumn', display_column.attname
                )::text
                FROM pg_catalog.pg_constraint fk
                JOIN pg_catalog.pg_class child ON child.oid = fk.conrelid
                JOIN pg_catalog.pg_namespace cn ON cn.oid = child.relnamespace
                JOIN pg_catalog.pg_class parent ON parent.oid = fk.confrelid
                JOIN pg_catalog.pg_namespace pn ON pn.oid = parent.relnamespace
                JOIN pg_catalog.pg_attribute ca ON ca.attrelid = child.oid AND ca.attnum = fk.conkey[1]
                JOIN pg_catalog.pg_attribute pa ON pa.attrelid = parent.oid AND pa.attnum = fk.confkey[1]
                JOIN pg_catalog.pg_type ct ON ct.oid = ca.atttypid
                JOIN pg_catalog.pg_type pt ON pt.oid = pa.atttypid
                JOIN pg_catalog.pg_namespace ctn ON ctn.oid = ct.typnamespace
                JOIN pg_catalog.pg_namespace ptn ON ptn.oid = pt.typnamespace
                LEFT JOIN LATERAL (
                    SELECT a.attname
                    FROM pg_catalog.pg_attribute a
                    JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
                    JOIN pg_catalog.pg_namespace tn ON tn.oid = t.typnamespace
                    WHERE a.attrelid = parent.oid AND a.attnum > 0 AND NOT a.attisdropped
                      AND a.attname IN ('name', 'display_name', 'business_name', 'title')
                      AND tn.nspname = 'pg_catalog' AND t.typname IN ('text', 'varchar', 'bpchar')
                      AND pg_catalog.has_column_privilege(parent.oid, a.attnum, 'SELECT')
                    ORDER BY CASE a.attname WHEN 'display_name' THEN 0 WHEN 'business_name' THEN 1 WHEN 'name' THEN 2 ELSE 3 END
                    LIMIT 1
                ) display_column ON true
                WHERE fk.contype = 'f' AND fk.convalidated
                  AND array_length(fk.conkey, 1) = 1 AND array_length(fk.confkey, 1) = 1
                  AND child.oid <> parent.oid
                  AND lower(pa.attname) !~ '(email|phone|mobile|address|password|passwd|secret|token|credential|signature|api.?key|account.?number|social.?security|ssn)'
                  AND (SELECT count(*) FROM pg_catalog.pg_constraint alternatives
                       WHERE alternatives.contype = 'f' AND alternatives.convalidated
                         AND alternatives.conrelid = fk.conrelid AND alternatives.confrelid = fk.confrelid) = 1
                  AND (cn.nspname, child.relname) IN (\(identities))
                  AND (pn.nspname, parent.relname) IN (\(identities))
                  AND pg_catalog.has_schema_privilege(cn.oid, 'USAGE')
                  AND pg_catalog.has_schema_privilege(pn.oid, 'USAGE')
                  AND pg_catalog.has_table_privilege(child.oid, 'SELECT')
                  AND pg_catalog.has_table_privilege(parent.oid, 'SELECT')
                  AND ctn.nspname = 'pg_catalog' AND ptn.nspname = 'pg_catalog'
                  AND ct.typname IN ('int2', 'int4', 'int8', 'numeric', 'uuid', 'text', 'varchar', 'bpchar')
                  AND pt.typname IN ('int2', 'int4', 'int8', 'numeric', 'uuid', 'text', 'varchar', 'bpchar')
                ORDER BY CASE WHEN lower(child.relname) IN ('bookings', 'appointments', 'reservations', 'games', 'orders', 'sessions', 'reads', 'article_reads') THEN 0 ELSE 1 END,
                         cn.nspname, child.relname, pn.nspname, parent.relname, ca.attname
                LIMIT 100
                """
            let rows = try await database.query(PostgresQuery(unsafeSQL: query), logger: logger)
            var relationships: [DatabaseRelationship] = []
            for try await payload in rows.decode(String.self) {
                guard let bytes = payload.data(using: .utf8), let relationship = try? JSONDecoder().decode(DatabaseRelationship.self, from: bytes) else { continue }
                relationships.append(relationship)
            }
            let eligible = DatabaseAnalytics.eligibleRelationships(relationships, tables: tables).sorted {
                let left = DatabaseAnalytics.discoveryPriority($0), right = DatabaseAnalytics.discoveryPriority($1)
                return left == right ? DatabaseAnalytics.relationshipID($0) < DatabaseAnalytics.relationshipID($1) : left < right
            }
            return Array(eligible.prefix(20))
        }
    }

    public static func recommendedTables(from relationships: [DatabaseRelationship]) -> [DatabaseTable] {
        DatabaseAnalytics.recommendedTables(from: relationships)
    }

    public static func configureAnalytics(base: ProjectConnection, tables: [DatabaseTable], relationships: [DatabaseRelationship], columns: [DatabaseColumn] = []) -> ProjectConnection {
        var result = DatabaseAnalytics.configure(base: base, tables: tables, relationships: relationships, columns: columns)
        result.sourceTables = tables
        return result
    }

    /// Reads only column/type metadata, including declared enum labels. Creation
    /// windows require timestamptz, so timezone-unknown local timestamps are not guessed.
    public func discoverColumns(connection: ProjectConnection, secret: String?, tables: [DatabaseTable]) async throws -> [DatabaseColumn] {
        guard connection.kind == .postgres else { throw PulseError.invalidConfiguration("Choose a PostgreSQL connection.") }
        guard !tables.isEmpty else { return [] }
        let query = try DatabaseAnalytics.columnDiscoveryQuery(tables: tables)
        var check = connection
        check.query = "SELECT 1 AS total"
        check.metrics = [MetricDefinition(label: "Total", path: "total")]
        try ConnectorValidation.validate(check)
        return try await withReadOnlyConnection(connection: check, secret: secret) { database, logger in
            let rows = try await database.query(PostgresQuery(unsafeSQL: query), logger: logger)
            var columns: [DatabaseColumn] = []
            for try await payload in rows.decode(String.self) {
                if let data = payload.data(using: .utf8), let column = try? JSONDecoder().decode(DatabaseColumn.self, from: data) {
                    columns.append(column)
                }
            }
            return columns
        }
    }

    public static func queryWithAnalytics(_ connection: ProjectConnection) throws -> String {
        try DatabaseAnalytics.queryWithAnalytics(connection)
    }

    /// Recognises only the exact simple count query emitted by this app. Custom
    /// queries, filters and joins retain their established meaning unchanged.
    public static func inferredSourceTables(connection: ProjectConnection, available: [DatabaseTable]) -> [DatabaseTable] {
        guard connection.kind == .postgres, connection.metrics.count <= 3 else { return [] }
        let matching = available.compactMap { table -> (Int, DatabaseTable)? in
            guard let schema = try? quotedIdentifier(table.schema), let name = try? quotedIdentifier(table.name),
                  let range = connection.query.range(of: "(SELECT count(*) FROM \(schema).\(name)) AS metric_") else { return nil }
            return (connection.query.distance(from: connection.query.startIndex, to: range.lowerBound), table)
        }.sorted { $0.0 < $1.0 }.map(\.1)
        guard (1...3).contains(matching.count), let rebuilt = try? countingConnection(base: connection, tables: matching), rebuilt.query == connection.query else { return [] }
        return matching
    }

    /// Selects from the exact ordered preview, never from a later catalog sort.
    /// Aliases are regenerated when the remaining tables are rebuilt.
    public static func selectedCountingConnection(base: ProjectConnection, metricPaths: Set<String>) throws -> ProjectConnection {
        guard base.kind == .postgres, let tables = base.sourceTables,
              (1...3).contains(tables.count), (1...3).contains(metricPaths.count),
              base.metrics.map(\.path) == tables.indices.map({ "metric_\($0)" }),
              metricPaths.isSubset(of: Set(base.metrics.map(\.path))) else {
            throw PulseError.invalidConfiguration("Choose numbers from the current database preview.")
        }
        let preview = try countingConnection(base: base, tables: tables)
        guard preview.query == base.query else {
            throw PulseError.invalidConfiguration("This database preview changed. Connect again before choosing its numbers.")
        }
        let selected = tables.enumerated().filter { metricPaths.contains("metric_\($0.offset)") }.map(\.element)
        return try countingConnection(base: base, tables: selected)
    }

    /// Builds one aggregate row without requiring people to write SQL.
    public static func countingConnection(base: ProjectConnection, tables: [DatabaseTable]) throws -> ProjectConnection {
        guard base.kind == .postgres else { throw PulseError.invalidConfiguration("Choose a PostgreSQL connection.") }
        guard (1...3).contains(tables.count) else { throw PulseError.invalidConfiguration("Choose one to three tables to count.") }
        let identities = tables.map { [$0.schema, $0.name] }
        guard Set(identities).count == tables.count else { throw PulseError.invalidConfiguration("Choose each table only once.") }
        var result = base
        let counts = try tables.enumerated().map { index, table in
            "(SELECT count(*) FROM \(try quotedIdentifier(table.schema)).\(try quotedIdentifier(table.name))) AS metric_\(index)"
        }
        result.query = "SELECT " + counts.joined(separator: ", ")
        let names = tables.map { ProjectSetup.friendlyLabel($0.name) }
        let duplicateNames = Dictionary(grouping: names.map { $0.lowercased() }, by: { $0 })
        var usedLabels: Set<String> = []
        result.metrics = tables.enumerated().map { index, table in
            // Records are an honest generic measure: no assumption about booking status or activity.
            let name = names[index]
            let qualified = (duplicateNames[name.lowercased()]?.count ?? 0) > 1 ? ProjectSetup.friendlyLabel(table.schema) + " · " + name : name
            var label = String(qualified.prefix(40))
            // Very long schema names can share a truncated prefix; retain distinct labels.
            var suffix = 2
            while usedLabels.contains(label.lowercased()) {
                let counter = " \(suffix)"
                label = String(qualified.prefix(40 - counter.count)) + counter
                suffix += 1
            }
            usedLabels.insert(label.lowercased())
            return MetricDefinition(label: label, path: "metric_\(index)")
        }
        result.sourceTables = tables
        if let plan = base.autoStats {
            result = DatabaseAnalytics.configure(base: result, tables: tables, relationships: plan.relationships, columns: plan.columns ?? [])
        }
        try ConnectorValidation.validate(result)
        return result
    }

    private static func quotedIdentifier(_ identifier: String) throws -> String {
        let controls = CharacterSet.controlCharacters
        guard !identifier.isEmpty, identifier.utf8.count <= 63,
              !identifier.unicodeScalars.contains(where: { controls.contains($0) }) else {
            throw PulseError.invalidConfiguration("A selected table name isn’t supported. Choose another table or use Advanced.")
        }
        return "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func withReadOnlyConnection<Value: Sendable>(connection: ProjectConnection, secret: String?, operation: @Sendable (PostgresConnection, Logger) async throws -> Value) async throws -> Value {
        guard let parts = URLComponents(string: connection.endpoint), let host = parts.host, let username = parts.user else { throw PulseError.invalidConfiguration("Enter a valid PostgreSQL connection URL.") }
        do {
            let local = ConnectorValidation.isLoopback(host)
            let disableLocalTLS = local && !(parts.queryItems ?? []).contains(where: { $0.name == "sslmode" && $0.value != "disable" })
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.certificateVerification = .fullVerification
            let tls: PostgresConnection.Configuration.TLS = disableLocalTLS ? .disable : .require(try NIOSSLContext(configuration: tlsConfiguration))
            var configuration = PostgresConnection.Configuration(host: host, port: parts.port ?? 5432, username: username, password: secret, database: String(parts.path.dropFirst()).removingPercentEncoding, tls: tls)
            configuration.options.connectTimeout = .seconds(10)
            let logger = Logger(label: "local.pulse.postgres", factory: { _ in SwiftLogNoOpLogHandler() })
            let database = try await PostgresConnection.connect(configuration: configuration, id: 1, logger: logger)
            do {
                try await database.query("BEGIN READ ONLY", logger: logger)
                try await database.query("SET LOCAL statement_timeout = '10s'", logger: logger)
                try await database.query("SET LOCAL lock_timeout = '3s'", logger: logger)
                try await database.query("SET LOCAL idle_in_transaction_session_timeout = '15s'", logger: logger)
                let value = try await operation(database, logger)
                try await database.query("ROLLBACK", logger: logger)
                try await database.close()
                return value
            } catch {
                try? await database.close()
                throw error
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as PulseError { throw error }
        catch { throw PulseError.response("Couldn’t read the database. Check the connection, credential, TLS and read-only query.") }
    }
}
