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
                // The subquery prevents transaction commands and bounds the result to two
                // rows so a mistakenly broad SELECT cannot download a table.
                let sql = "SELECT row_to_json(pulse_summary)::text AS pulse_json FROM (\(connection.query)) AS pulse_summary LIMIT 2"
                let rows = try await database.query(PostgresQuery(unsafeSQL: sql), logger: logger)
                var payloads: [String] = []
                for try await payload in rows.decode(String.self) { payloads.append(payload) }
                guard payloads.count == 1, let data = payloads.first?.data(using: .utf8) else { throw PulseError.response("The query must return exactly one summary row.") }
                let snapshot = try HTTPConnector.snapshot(data: data, connection: connection)
                try await database.query("ROLLBACK", logger: logger)
                try await database.close()
                return snapshot
            } catch {
                try? await database.close()
                throw error
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as PulseError { throw error }
        catch { throw PulseError.response("Couldn’t read the database. Check the connection, credential, TLS and read-only query.") }
    }
}
