import Foundation
import CoreFoundation

/// Values are mapped with simple dotted paths, e.g. `stats.readers` or `items.0.count`.
/// Responses and credentials never appear in user-facing errors.
public struct HTTPConnector: SummaryConnector {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    public static let maximumResponseBytes = 1_048_576

    public init() { transport = { request in try await Self.fetch(request) } }
    public init(transport: @escaping Transport) { self.transport = transport }

    public func collect(connection: ProjectConnection, secret: String?) async throws -> ProjectSnapshot {
        try Self.snapshot(data: await requestData(connection: connection, secret: secret), connection: connection)
    }

    /// Finds a small set of summary numbers without requiring callers to know JSON paths.
    /// Credentials and complete provider responses never leave the connector.
    public func discover(connection: ProjectConnection, secret: String?) async throws -> [DiscoveredMetric] {
        var preview = connection
        preview.metrics = [MetricDefinition(label: "Preview", path: "preview")]
        let data = try await requestData(connection: preview, secret: secret)
        let found = try Self.discover(data: data)
        if let first = found.first {
            preview.metrics = [MetricDefinition(label: first.label, path: first.path)]
            // Validate the same event/date contract used by collection before setup
            // reports success. This reuses the payload and makes no second request.
            _ = try Self.snapshot(data: data, connection: preview)
        }
        return found
    }

    private func requestData(connection: ProjectConnection, secret: String?) async throws -> Data {
        guard connection.kind == .http else { throw PulseError.invalidConfiguration("Choose an HTTP source for this URL.") }
        try ConnectorValidation.validate(connection)
        guard let url = URL(string: connection.endpoint) else { throw PulseError.invalidConfiguration("Enter a valid endpoint URL.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let secret, !secret.isEmpty {
            guard !secret.contains("\r"), !secret.contains("\n") else { throw PulseError.invalidConfiguration("The credential contains an invalid line break.") }
            request.setValue(secret, forHTTPHeaderField: connection.authHeader)
        }
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as PulseError { throw error }
        catch { throw PulseError.response("Couldn’t reach the endpoint. Check your connection and try again.") }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 { throw PulseError.response("Access denied. Check the saved credential and endpoint permissions.") }
            if (300..<400).contains(response.statusCode) { throw PulseError.response("The endpoint redirected. Enter its final URL instead.") }
            if response.statusCode == 429 { throw PulseError.response("The service is limiting requests. Try a longer refresh interval.") }
            throw PulseError.response("The service returned HTTP \(response.statusCode). Try again later.")
        }
        guard data.count <= Self.maximumResponseBytes else { throw PulseError.response("The response is too large. Use a small summary endpoint.") }
        return data
    }

    public static func snapshot(data: Data, connection: ProjectConnection, now: Date = Date()) throws -> ProjectSnapshot {
        let object = try summaryObject(data)
        let values = try connection.metrics.map { definition in
            let value = try scalar(at: definition.path, in: object)
            return MetricValue(id: definition.id, label: definition.label, value: value)
        }
        var measuredAt = now
        if let rawDate = object["measuredAt"] ?? object["measured_at"] ?? object["measuredat"] {
            guard let text = rawDate as? String, let date = parseDate(text), date <= now.addingTimeInterval(300) else {
                throw PulseError.response("The summary has an invalid measurement date.")
            }
            measuredAt = date
        }
        let coverage = (object["coverage"] as? String).map { String($0.prefix(160)) }
        var events: [PulseEvent] = []
        if let rawEvents = object["events"] {
            guard let rows = rawEvents as? [[String: Any]], rows.count <= 1_000 else { throw PulseError.response("The events field must contain at most 1,000 events.") }
            var eventIDs: Set<String> = []
            for row in rows {
                guard let id = row["id"] as? String, !id.isEmpty, id.count <= 200,
                      let title = row["title"] as? String, !title.isEmpty, title.count <= 300,
                      let dateString = (row["occurredAt"] ?? row["occurred_at"]) as? String, let date = parseDate(dateString), date <= now.addingTimeInterval(300)
                else { throw PulseError.response("Each event needs a stable ID, a short title and an ISO 8601 date.") }
                if eventIDs.insert(id).inserted {
                    let link = (row["url"] as? String).flatMap { safeLink($0) }
                    events.append(PulseEvent(id: id, title: title, occurredAt: date, url: link))
                }
            }
        }
        let details = expandedMetrics(in: object, connection: connection)
        let breakdowns = expandedBreakdowns(in: object, projectID: connection.id)
        return ProjectSnapshot(projectID: connection.id, metrics: values, events: events.sorted { $0.occurredAt < $1.occurredAt }, measuredAt: measuredAt, fetchedAt: now, coverage: coverage, details: details.isEmpty ? nil : details, breakdowns: breakdowns.isEmpty ? nil : breakdowns)
    }

    public static func discover(data: Data) throws -> [DiscoveredMetric] {
        let object = try summaryObject(data)
        let found = discoverSummaryNumbers(in: object)
        guard !found.isEmpty else { throw PulseError.response("No summary numbers found. Use an endpoint with numeric totals, or choose Advanced to map values yourself.") }
        return found
    }

    private static func discoverSummaryNumbers(in object: [String: Any]) -> [DiscoveredMetric] {
        let metrics = object["metrics"] as? [String: Any]
        let root = metrics ?? object
        let rootPath = metrics == nil ? [] : ["metrics"]
        return discoverNumbers(in: root, rootObject: object, path: rootPath, depth: rootPath.count, remaining: 30)
    }

    /// Optional expanded summaries never require another request. Only numeric
    /// summary fields are inferred; record arrays and identities are not explored.
    private static func expandedMetrics(in object: [String: Any], connection: ProjectConnection) -> [MetricValue] {
        let headlinePaths = Set(connection.metrics.map(\.path))
        var labels = Set(connection.metrics.map { normalizedLabel($0.label) })
        var identities: Set<String> = []
        var details: [MetricValue] = []
        let explicit = object["__pulse_details"] ?? object["details"]

        if let fields = explicit as? [String: Any] {
            // The explicit details container is deliberately not part of headline discovery.
            for candidate in discoverNumbers(in: fields, rootObject: fields, path: [], depth: 0, remaining: 30) {
                guard details.count < 6 else { break }
                let originalPath = object["__pulse_details"] == nil ? "details." + candidate.path : "__pulse_details." + candidate.path
                let label = normalizedLabel(candidate.label)
                guard !headlinePaths.contains(originalPath), labels.insert(label).inserted else { continue }
                identities.insert(candidate.path)
                details.append(MetricValue(id: MetricIdentity.uuid(projectID: connection.id, path: "details:" + candidate.path), label: candidate.label, value: candidate.previewValue))
            }
        } else if let rows = explicit as? [[String: Any]] {
            for row in rows.prefix(60) {
                guard details.count < 6 else { break }
                guard let label = cleanText(row["label"], limit: 40),
                      let value = displayValue(row["value"]) else { continue }
                let identity = cleanText(row["id"], limit: 200) ?? label
                guard !headlinePaths.contains(identity), identities.insert(identity).inserted,
                      labels.insert(normalizedLabel(label)).inserted else { continue }
                details.append(MetricValue(id: MetricIdentity.uuid(projectID: connection.id, path: "details:" + identity), label: label, value: value))
            }
        }

        for candidate in discoverSummaryNumbers(in: object) {
            guard details.count < 6 else { break }
            guard !headlinePaths.contains(candidate.path), labels.insert(normalizedLabel(candidate.label)).inserted else { continue }
            details.append(MetricValue(id: MetricIdentity.uuid(projectID: connection.id, path: "extra:" + candidate.path), label: candidate.label, value: candidate.previewValue))
        }
        return details
    }

    private static func expandedBreakdowns(in object: [String: Any], projectID: UUID) -> [MetricBreakdown] {
        guard let groups = (object["__pulse_breakdowns"] ?? object["breakdowns"]) as? [[String: Any]] else { return [] }
        var result: [MetricBreakdown] = []
        var groupIDs: Set<String> = []
        for group in groups.prefix(20) {
            guard result.count < 2 else { break }
            guard let title = cleanText(group["title"], limit: 80),
                  let rawRows = group["rows"] as? [[String: Any]] else { continue }
            let identity = cleanText(group["id"], limit: 200) ?? title
            guard groupIDs.insert(identity).inserted else { continue }
            var rows: [MetricBreakdownRow] = []
            var seenIDs: Set<String> = []
            var labelOccurrences: [String: Int] = [:]
            for rawRow in rawRows.prefix(100) {
                guard let label = cleanText(rawRow["label"], limit: 80),
                      let value = displayValue(rawRow["value"]) else { continue }
                let rowID: String
                if let provided = cleanText(rawRow["id"], limit: 200) { rowID = provided }
                else {
                    // Identical display names do not establish identical people.
                    let occurrence = (labelOccurrences[label] ?? 0) + 1
                    labelOccurrences[label] = occurrence
                    rowID = "label:\(label):\(occurrence)"
                }
                guard seenIDs.insert(rowID).inserted else { continue }
                // Read one extra valid row so the drawer can accurately indicate a cap.
                rows.append(MetricBreakdownRow(id: rowID, label: label, value: value))
                if rows.count == 11 { break }
            }
            guard !rows.isEmpty else { continue }
            let truncated = (group["truncated"] as? Bool == true) || rows.count > 10 || rawRows.count > 100
            result.append(MetricBreakdown(id: MetricIdentity.uuid(projectID: projectID, path: "breakdown:" + identity).uuidString,
                                          title: title, rows: Array(rows.prefix(10)), truncated: truncated))
        }
        return result
    }

    private static func cleanText(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let controls = CharacterSet.controlCharacters
        guard !trimmed.isEmpty, trimmed.count <= limit,
              !trimmed.unicodeScalars.contains(where: { controls.contains($0) }) else { return nil }
        return trimmed
    }

    private static func displayValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let number = value as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        if let string = value as? String,
           cleanText(string, limit: 120) == nil { return nil }
        return try? scalar(at: "value", in: ["value": value])
    }

    private static func normalizedLabel(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func discoverNumbers(in dictionary: [String: Any], rootObject: [String: Any], path: [String], depth: Int, remaining: Int) -> [DiscoveredMetric] {
        guard depth < 5, remaining > 0 else { return [] }
        var found: [DiscoveredMetric] = []
        let controls = CharacterSet.controlCharacters
        for key in dictionary.keys.sorted() {
            guard found.count < remaining else { break }
            guard !key.isEmpty, key.count <= 96, !key.contains("."),
                  !key.unicodeScalars.contains(where: { controls.contains($0) }),
                  !isPrivateOrMetadataKey(key) else { continue }
            let nextPath = path + [key]
            let joined = nextPath.joined(separator: ".")
            guard joined.count <= 128, let value = dictionary[key] else { continue }
            if let nested = value as? [String: Any] {
                found += discoverNumbers(in: nested, rootObject: rootObject, path: nextPath, depth: depth + 1, remaining: remaining - found.count)
            } else if isSummaryNumber(value), let preview = try? scalar(at: joined, in: rootObject) {
                let namespace = nextPath.drop { ["metrics", "stats", "summary", "data"].contains($0.lowercased()) }
                let label = namespace.map(ProjectSetup.friendlyLabel).joined(separator: " ")
                found.append(DiscoveredMetric(path: joined, label: String(label.prefix(40)), previewValue: preview))
            }
        }
        return found
    }

    private static func summaryObject(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumResponseBytes else { throw PulseError.response("The response is too large. Use a small summary endpoint.") }
        guard let root = try? JSONSerialization.jsonObject(with: data), let object = root as? [String: Any] else {
            throw PulseError.response("The endpoint must return a JSON object.")
        }
        return object
    }

    private static func isSummaryNumber(_ value: Any) -> Bool {
        if let number = value as? NSNumber {
            return CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.isFinite
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 24,
                  trimmed.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
                  let number = Double(trimmed), number.isFinite else { return false }
            return true
        }
        return false
    }

    private static func isPrivateOrMetadataKey(_ key: String) -> Bool {
        let words = key.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let compact = words.joined()
        let privateWords: Set<String> = ["id", "ids", "uuid", "email", "phone", "mobile", "password", "secret", "token", "key", "apikey", "credential", "credentials", "authorization", "signature", "address", "latitude", "longitude", "lat", "lng", "postcode", "zipcode", "dob"]
        if words.contains(where: privateWords.contains) { return true }
        if ["key", "apikey", "accesskey", "privatekey", "publickey", "accountnumber", "phonenumber", "ip", "ipaddress", "events", "timestamp", "createdat", "updatedat", "measuredat", "occurredat", "fetchedat", "date", "time", "details", "breakdowns", "pulsedetails", "pulsebreakdowns"].contains(compact) { return true }
        return compact.hasSuffix("timestamp") || compact.hasSuffix("uuid") || compact.hasSuffix("datetime")
            || ["createdat", "updatedat", "measuredat", "occurredat", "fetchedat", "lastseen", "lastactive", "lastlogin"].contains(where: compact.hasPrefix)
    }

    private static func scalar(at path: String, in root: [String: Any]) throws -> String {
        var current: Any = root
        for component in path.split(separator: ".", omittingEmptySubsequences: false) {
            if let dictionary = current as? [String: Any], let next = dictionary[String(component)] { current = next }
            else if let array = current as? [Any], let index = Int(component), array.indices.contains(index) { current = array[index] }
            else { throw PulseError.response("A selected metric is missing. Check its JSON path.") }
        }
        if let string = current as? String {
            guard string.count <= 120 else { throw PulseError.response("A metric is too long. Return a short value.") }
            return string
        }
        if let number = current as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "Yes" : "No" }
            guard number.doubleValue.isFinite else { throw PulseError.response("A metric must be a finite number.") }
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 4
            return formatter.string(from: number) ?? number.stringValue
        }
        throw PulseError.response("A selected metric isn’t a number or short text value.")
    }

    public static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    public static func safeLink(_ value: String) -> String? {
        guard let url = URL(string: value), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""), parts.host != nil,
              parts.user == nil, parts.password == nil else { return nil }
        return url.absoluteString
    }

    private static func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else { throw PulseError.response("The service didn’t return an HTTP response.") }
        guard response.expectedContentLength <= maximumResponseBytes else { throw PulseError.response("The response is too large. Use a small summary endpoint.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else { throw PulseError.response("The response is too large. Use a small summary endpoint.") }
            data.append(byte)
        }
        return (data, response)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum ConnectorValidation {
    public static func validate(_ connection: ProjectConnection) throws {
        guard !connection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, connection.name.count <= 60 else { throw PulseError.invalidConfiguration("Give the project a name of up to 60 characters.") }
        guard (1...3).contains(connection.metrics.count), connection.metrics.allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.label.count <= 40 && !$0.path.isEmpty && $0.path.count <= 128 && !$0.path.split(separator: ".", omittingEmptySubsequences: false).contains("") }) else { throw PulseError.invalidConfiguration("Add one to three metrics, each with a short label and a value path.") }
        guard (60...86_400).contains(connection.intervalSeconds) else { throw PulseError.invalidConfiguration("Choose a refresh interval between one minute and one day.") }
        guard let parts = URLComponents(string: connection.endpoint), let host = parts.host, !host.isEmpty,
              parts.password == nil, parts.fragment == nil else { throw PulseError.invalidConfiguration("Enter a valid endpoint. Save credentials separately.") }
        if connection.kind == .http {
            let scheme = parts.scheme?.lowercased()
            guard (scheme == "https" || (scheme == "http" && isLoopback(host))), parts.user == nil else { throw PulseError.invalidConfiguration("Use HTTPS, or HTTP on localhost. Save credentials separately.") }
            let secretKeys = ["key", "api_key", "apikey", "token", "access_token", "password", "secret", "authorization", "signature"]
            guard !(parts.queryItems ?? []).contains(where: { secretKeys.contains($0.name.lowercased()) }) else { throw PulseError.invalidConfiguration("Move the credential out of the URL and into the secure credential field.") }
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
            guard !connection.authHeader.isEmpty, connection.authHeader.unicodeScalars.allSatisfy(allowed.contains), !["host", "content-length", "connection", "cookie"].contains(connection.authHeader.lowercased()) else { throw PulseError.invalidConfiguration("Enter a valid authentication header name.") }
        } else {
            guard ["postgres", "postgresql"].contains(parts.scheme?.lowercased() ?? ""), let user = parts.user, !user.isEmpty, parts.path.count > 1, (parts.port ?? 5432) > 0, (parts.port ?? 5432) <= 65535 else { throw PulseError.invalidConfiguration("Use postgresql://user@host:5432/database, with the password saved separately.") }
            let items = parts.queryItems ?? []
            guard items.allSatisfy({ $0.name == "sslmode" && ["require", "verify-full", "disable"].contains($0.value ?? "") }), !items.contains(where: { $0.value == "disable" && !isLoopback(host) }) else { throw PulseError.invalidConfiguration("Remote databases require verified TLS. Only sslmode=require or verify-full is supported remotely.") }
            try validatePostgresQuery(connection.query)
        }
    }

    /// This is an early UX guard. The database transaction is always READ ONLY;
    /// a restricted read-only database role is still required for least privilege.
    public static func validatePostgresQuery(_ query: String) throws {
        let sql = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = sql.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first?.uppercased()
        guard sql.count <= 16_384, ["SELECT", "WITH"].contains(first ?? ""), !sql.contains(";"), !sql.contains("--"), !sql.contains("/*"), !sql.contains("*/") else { throw PulseError.invalidConfiguration("Use one SELECT or WITH query without semicolons or SQL comments.") }
        let blocked = #"(?i)\b(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|TRUNCATE|COPY|CALL|DO|GRANT|REVOKE|SET|RESET|COMMIT|ROLLBACK|VACUUM|INTO|FOR\s+UPDATE|FOR\s+SHARE)\b"#
        guard sql.range(of: blocked, options: .regularExpression) == nil else { throw PulseError.invalidConfiguration("Only read-only aggregate SELECT queries are supported.") }
        let sideEffects = #"(?i)\b(set_config|nextval|setval|pg_notify|pg_sleep|pg_advisory_lock|pg_advisory_xact_lock|pg_try_advisory_lock|pg_read_file|pg_read_binary_file|pg_write_file|pg_cancel_backend|pg_terminate_backend|lo_import|lo_export|dblink|dblink_exec)\s*\("#
        guard sql.range(of: sideEffects, options: .regularExpression) == nil else { throw PulseError.invalidConfiguration("Use a summary query without session changes or side-effect functions.") }
    }

    public static func isLoopback(_ host: String) -> Bool { ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) }
}
