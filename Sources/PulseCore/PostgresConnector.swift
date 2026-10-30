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
            // The subquery prevents transaction commands and bounds the result to two
            // rows so a mistakenly broad SELECT cannot download a table.
            let sql = "SELECT row_to_json(pulse_summary)::text AS pulse_json FROM (\(connection.query)) AS pulse_summary LIMIT 2"
            let rows = try await database.query(PostgresQuery(unsafeSQL: sql), logger: logger)
            var payloads: [String] = []
            for try await payload in rows.decode(String.self) { payloads.append(payload) }
            guard payloads.count == 1, let data = payloads.first?.data(using: .utf8) else { throw PulseError.response("The query must return exactly one summary row.") }
            return try HTTPConnector.snapshot(data: data, connection: connection)
        }
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
            var label = String(qualified.prefix(32)) + " records"
            // Very long schema names can share a truncated prefix; retain distinct labels.
            var suffix = 2
            while usedLabels.contains(label.lowercased()) {
                let counter = " \(suffix)"
                label = String(qualified.prefix(32 - counter.count)) + counter + " records"
                suffix += 1
            }
            usedLabels.insert(label.lowercased())
            return MetricDefinition(label: label, path: "metric_\(index)")
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
