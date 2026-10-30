import Foundation

/// A count-only Data API plan. It contains table/filter metadata, never credentials.
public struct SupabaseRESTPlan: Codable, Equatable, Sendable {
    public var version: Int
    public var defaultRange: String
    public var timeZone: String
    public var coverage: String?
    public var metrics: [SupabaseRESTMetric]
    public init(version: Int = 1, defaultRange: String = "7d", timeZone: String = "Europe/London", coverage: String? = nil, metrics: [SupabaseRESTMetric]) {
        self.version = version; self.defaultRange = defaultRange; self.timeZone = timeZone; self.coverage = coverage; self.metrics = metrics
    }
    public func encodedQuery() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}

public struct SupabaseRESTFilter: Codable, Equatable, Sendable {
    public var column: String
    public var value: String
    public init(column: String, value: String) { self.column = column; self.value = value }
}

public struct SupabaseRESTMetric: Codable, Equatable, Sendable {
    public var key: String
    public var table: String
    public var select: String?
    public var filters: [SupabaseRESTFilter]?
    public var timeColumn: String?
    public var daily: Bool?
    public var notificationCounter: Bool?
    public var finiteLabel: String?
    public var counterLabel: String?
    public var unitSingular: String?
    public var unitPlural: String?
    public init(key: String, table: String, select: String = "id", filters: [SupabaseRESTFilter] = [], timeColumn: String? = nil, daily: Bool = false, notificationCounter: Bool = false, finiteLabel: String? = nil, counterLabel: String? = nil, unitSingular: String? = nil, unitPlural: String? = nil) {
        self.key = key; self.table = table; self.select = select; self.filters = filters; self.timeColumn = timeColumn; self.daily = daily; self.notificationCounter = notificationCounter; self.finiteLabel = finiteLabel; self.counterLabel = counterLabel; self.unitSingular = unitSingular; self.unitPlural = unitPlural
    }
}

/// Uses either Supabase's restricted SQL endpoint or HEAD-only exact Data API counts.
public struct SupabaseConnector: SummaryConnector {
    public typealias Transport = HTTPConnector.Transport
    private let transport: Transport
    private static let ranges = ["24h", "7d", "30d", "lifetime"]
    public init() { transport = { request in try await HTTPConnector.fetch(request) } }
    public init(transport: @escaping Transport) { self.transport = transport }

    public func collect(connection: ProjectConnection, secret: String?) async throws -> ProjectSnapshot {
        try await collect(connection: connection, secret: secret, now: Date())
    }

    public func collect(connection: ProjectConnection, secret: String?, now: Date) async throws -> ProjectSnapshot {
        guard connection.kind == .supabase else { throw PulseError.invalidConfiguration("Choose a Supabase source for this connection.") }
        try ConnectorValidation.validate(connection)
        let token = try Self.token(secret)
        let data: Data
        switch try Self.route(connection.endpoint) {
        case .sql(let url):
            var request = Self.request(url: url, token: token)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": connection.query])
            let (body, _) = try await perform(request)
            guard let rows = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]], rows.count == 1 else {
                throw PulseError.response("The summary query must return exactly one JSON row.")
            }
            data = try JSONSerialization.data(withJSONObject: rows[0])
        case .rest(let url):
            let plan = try Self.plan(connection.query)
            data = try await restSummary(plan: plan, connection: connection, endpoint: url, token: token, now: now)
        }
        return try HTTPConnector.snapshot(data: data, connection: connection, now: now)
    }

    /// Called by shared connection validation; this method never makes a request.
    public static func validate(_ connection: ProjectConnection) throws {
        guard connection.kind == .supabase else { throw PulseError.invalidConfiguration("Choose a Supabase source for this connection.") }
        switch try route(connection.endpoint) {
        case .sql:
            try ConnectorValidation.validatePostgresQuery(connection.query)
        case .rest:
            let decoded = try plan(connection.query)
            let paths = Set(decoded.metrics.map { "metrics." + $0.key })
            guard connection.metrics.allSatisfy({ paths.contains($0.path) }) else {
                throw PulseError.invalidConfiguration("Map each metric to a count in the Supabase plan.")
            }
        }
    }

    private enum Route { case sql(URL), rest(URL) }
    private static func route(_ endpoint: String) throws -> Route {
        guard let parts = URLComponents(string: endpoint), parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.port == nil || parts.port == 443,
              parts.percentEncodedPath == parts.path, let host = parts.host?.lowercased(), let url = parts.url else {
            throw PulseError.invalidConfiguration("Use a Supabase project URL and save its credential separately.")
        }
        if host == "api.supabase.com", matches(parts.path, #"^/v1/projects/[a-z0-9]{20}/database/query/read-only$"#) { return .sql(url) }
        if matches(host, #"^[a-z0-9]{20}\.supabase\.co$"#), ["/rest/v1", "/rest/v1/"].contains(parts.path) { return .rest(url) }
        throw PulseError.invalidConfiguration("Use the project's Supabase Data API or read-only query endpoint.")
    }

    private static func plan(_ query: String) throws -> SupabaseRESTPlan {
        guard query.utf8.count <= 16_384, let data = query.data(using: .utf8), let plan = try? JSONDecoder().decode(SupabaseRESTPlan.self, from: data),
              plan.version == 1, ranges.contains(plan.defaultRange), TimeZone(identifier: plan.timeZone) != nil,
              (1...3).contains(plan.metrics.count), Set(plan.metrics.map(\.key)).count == plan.metrics.count,
              plan.coverage.map({ clean($0, limit: 500) }) ?? true else {
            throw PulseError.invalidConfiguration("Use a supported Supabase count plan with one to three metrics.")
        }
        for metric in plan.metrics {
            let select = metric.select ?? "id"
            guard matches(metric.key, #"^[A-Za-z][A-Za-z0-9_]{0,39}$"#), identifier(metric.table),
                  !select.isEmpty, select.count <= 300,
                  matches(select, #"^[A-Za-z0-9_.,!():]+$"#), (metric.filters?.count ?? 0) <= 12,
                  metric.timeColumn.map(column) ?? true, metric.daily != true || metric.timeColumn != nil,
                  [metric.finiteLabel, metric.counterLabel, metric.unitSingular, metric.unitPlural].allSatisfy({ $0.map { clean($0, limit: 40) } ?? true }) else {
                throw PulseError.invalidConfiguration("The Supabase count plan contains an unsupported table or field.")
            }
            for filter in metric.filters ?? [] {
                let logic = ["and", "or"].contains(filter.column)
                let validValue = logic ? filter.value.hasPrefix("(") && filter.value.hasSuffix(")") : ["eq.", "neq.", "gt.", "gte.", "lt.", "lte.", "is.", "in.", "not."].contains(where: filter.value.hasPrefix)
                guard (logic || column(filter.column)), !["select", "limit", "offset", "order"].contains(filter.column),
                      clean(filter.value, limit: 1_024), validValue,
                      !filter.value.replacingOccurrences(of: "{{now}}", with: "").contains("{{") else {
                    throw PulseError.invalidConfiguration("The Supabase count plan contains an unsupported filter.")
                }
            }
        }
        return plan
    }

    private struct CountJob: Sendable {
        var metric: SupabaseRESTMetric
        var range: String
        var lower: Date?
        var upper: Date?
        var identity: String { metric.key + ":" + range }
    }

    private func restSummary(plan: SupabaseRESTPlan, connection: ProjectConnection, endpoint: URL, token: String, now: Date) async throws -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: plan.timeZone)!
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        var jobs: [CountJob] = []
        for metric in plan.metrics {
            jobs.append(CountJob(metric: metric, range: "lifetime"))
            if metric.timeColumn != nil {
                for (range, seconds) in [("24h", 86_400.0), ("7d", 604_800.0), ("30d", 2_592_000.0)] {
                    jobs.append(CountJob(metric: metric, range: range, lower: now.addingTimeInterval(-seconds), upper: now))
                }
                if metric.daily == true {
                    jobs.append(CountJob(metric: metric, range: "today", lower: today, upper: now))
                    jobs.append(CountJob(metric: metric, range: "yesterday", lower: yesterday, upper: today))
                }
            }
        }
        let counts = try await count(jobs: jobs, endpoint: endpoint, token: token, now: now)
        let definitions = connection.metrics.reduce(into: [String: String]()) { $0[$1.path] = $1.label }
        func payload(_ range: String) -> [String: Any] {
            var values: [String: Int64] = [:]
            var labels: [String: String] = [:]
            for metric in plan.metrics {
                values[metric.key] = counts[metric.key + ":" + (metric.timeColumn == nil ? "lifetime" : range)]!
                if range != "lifetime", let label = metric.finiteLabel { labels["metrics." + metric.key] = label }
            }
            var result: [String: Any] = ["metrics": values, "labels": labels]
            if let coverage = plan.coverage { result["coverage"] = coverage }
            return result
        }
        var result = payload(plan.defaultRange)
        result["ranges"] = Dictionary(uniqueKeysWithValues: Self.ranges.map { ($0, payload($0)) })
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: now)
        let day = String(format: "%04d-%02d-%02d", dayComponents.year!, dayComponents.month!, dayComponents.day!)
        var counters: [[String: Any]] = [], daily: [[String: Any]] = []
        for metric in plan.metrics {
            let label = metric.counterLabel ?? definitions["metrics." + metric.key] ?? ProjectSetup.friendlyLabel(metric.key)
            if metric.notificationCounter == true {
                var counter: [String: Any] = ["id": "supabase:" + metric.key, "label": label, "value": counts[metric.key + ":lifetime"]!]
                if let unit = metric.unitSingular { counter["unitSingular"] = unit }
                if let unit = metric.unitPlural { counter["unitPlural"] = unit }
                counters.append(counter)
            }
            if metric.daily == true {
                daily.append(["id": "supabase:daily:" + metric.key, "label": definitions["metrics." + metric.key] ?? label, "today": counts[metric.key + ":today"]!, "yesterday": counts[metric.key + ":yesterday"]!, "day": day])
            }
        }
        result["alerts"] = ["counters": counters, "daily": daily]
        return try JSONSerialization.data(withJSONObject: result)
    }

    private func count(jobs: [CountJob], endpoint: URL, token: String, now: Date) async throws -> [String: Int64] {
        try await withThrowingTaskGroup(of: (String, Int64).self) { group in
            var next = 0, values: [String: Int64] = [:]
            func enqueue(_ job: CountJob) {
                group.addTask {
                    try Task.checkCancellation()
                    var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
                    parts.path = "/rest/v1/" + job.metric.table
                    var items = [URLQueryItem(name: "select", value: job.metric.select ?? "id")]
                    items += (job.metric.filters ?? []).map { URLQueryItem(name: $0.column, value: $0.value.replacingOccurrences(of: "{{now}}", with: Self.iso(now))) }
                    if let column = job.metric.timeColumn, let lower = job.lower { items.append(URLQueryItem(name: column, value: "gte." + Self.iso(lower))) }
                    if let column = job.metric.timeColumn, let upper = job.upper { items.append(URLQueryItem(name: column, value: "lt." + Self.iso(upper))) }
                    parts.queryItems = items
                    var request = Self.request(url: parts.url!, token: token)
                    request.httpMethod = "HEAD"
                    request.setValue(token, forHTTPHeaderField: "apikey")
                    request.setValue("count=exact", forHTTPHeaderField: "Prefer")
                    request.setValue("0-0", forHTTPHeaderField: "Range")
                    request.setValue("items", forHTTPHeaderField: "Range-Unit")
                    let (_, response) = try await perform(request)
                    guard let contentRange = response.value(forHTTPHeaderField: "Content-Range"), Self.matches(contentRange, #"^(?:[0-9]+-[0-9]+|\*)/[0-9]+$"#),
                          let total = contentRange.split(separator: "/", omittingEmptySubsequences: false).last,
                          !total.isEmpty, total.allSatisfy(\.isASCII), total.allSatisfy(\.isNumber), let value = Int64(total), value >= 0 else {
                        throw PulseError.response("Supabase did not return an exact count. Check the table and count permissions.")
                    }
                    return (job.identity, value)
                }
            }
            while next < min(3, jobs.count) { enqueue(jobs[next]); next += 1 }
            while let (identity, value) = try await group.next() {
                values[identity] = value
                if next < jobs.count { enqueue(jobs[next]); next += 1 }
            }
            return values
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw PulseError.response("Couldn’t reach Supabase. Check your connection and try again.") }
        guard data.count <= HTTPConnector.maximumResponseBytes else { throw PulseError.response("The Supabase summary is too large.") }
        guard response.url == request.url else { throw PulseError.response("Supabase redirected the request. Check the project endpoint.") }
        switch response.statusCode {
        case 200..<300: return (data, response)
        case 401, 403: throw PulseError.response("Access denied. Check the saved Supabase credential and permissions.")
        case 300..<400: throw PulseError.response("Supabase redirected the request. Check the project endpoint.")
        case 429: throw PulseError.response("Supabase is limiting requests. Try a longer refresh interval.")
        default: throw PulseError.response("Supabase returned HTTP \(response.statusCode). Try again later.")
        }
    }

    private static func request(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }
    private static func token(_ secret: String?) throws -> String {
        var token = secret ?? ""
        if token.hasPrefix("Bearer ") { token.removeFirst(7) }
        guard !token.isEmpty, token.utf8.count <= 8_192, !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw PulseError.invalidConfiguration("Save a valid Supabase credential in the secure credential field.")
        }
        return token
    }
    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func identifier(_ value: String) -> Bool { matches(value, #"^[A-Za-z_][A-Za-z0-9_]{0,62}$"#) }
    private static func column(_ value: String) -> Bool { !value.isEmpty && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { identifier(String($0)) } && value.count <= 190 }
    private static func clean(_ value: String, limit: Int) -> Bool {
        let controls = CharacterSet.controlCharacters
        return !value.isEmpty && value.count <= limit && !value.unicodeScalars.contains(where: { controls.contains($0) })
    }
    private static func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
}
