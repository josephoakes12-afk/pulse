import CoreFoundation
import Foundation

/// A count-only Data API plan. It contains table/filter metadata, never credentials.
public struct SupabaseRESTPlan: Codable, Equatable, Sendable {
    public var version: Int
    public var defaultRange: String
    public var timeZone: String
    public var coverage: String?
    public var metrics: [SupabaseRESTMetric]
    public var details: [SupabaseRESTMetric]?
    public var ratios: [SupabaseRESTRatio]?
    public var breakdowns: [SupabaseRESTBreakdown]?
    public init(version: Int = 1, defaultRange: String = "7d", timeZone: String = "Europe/London", coverage: String? = nil, metrics: [SupabaseRESTMetric], details: [SupabaseRESTMetric]? = nil, ratios: [SupabaseRESTRatio]? = nil, breakdowns: [SupabaseRESTBreakdown]? = nil) {
        self.version = version; self.defaultRange = defaultRange; self.timeZone = timeZone; self.coverage = coverage; self.metrics = metrics
        self.details = details; self.ratios = ratios; self.breakdowns = breakdowns
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
    public var label: String?
    public var allTime: Bool?
    public init(key: String, table: String, select: String = "id", filters: [SupabaseRESTFilter] = [], timeColumn: String? = nil, daily: Bool = false, notificationCounter: Bool = false, finiteLabel: String? = nil, counterLabel: String? = nil, unitSingular: String? = nil, unitPlural: String? = nil, label: String? = nil, allTime: Bool = false) {
        self.key = key; self.table = table; self.select = select; self.filters = filters; self.timeColumn = timeColumn; self.daily = daily; self.notificationCounter = notificationCounter; self.finiteLabel = finiteLabel; self.counterLabel = counterLabel; self.unitSingular = unitSingular; self.unitPlural = unitPlural
        self.label = label; self.allTime = allTime
    }
}

/// Derived only from explicitly scoped exact counts; no guessed population joins.
public struct SupabaseRESTRatio: Codable, Equatable, Sendable {
    public var key: String
    public var label: String
    public var numerator: String
    public var denominator: String
    public var numeratorRange: String?
    public var denominatorRange: String?
    public var multiplier: Double?
    public var precision: Int?
    public init(key: String, label: String, numerator: String, denominator: String, numeratorRange: String? = nil, denominatorRange: String? = nil, multiplier: Double = 1, precision: Int = 1) {
        self.key = key; self.label = label; self.numerator = numerator; self.denominator = denominator
        self.numeratorRange = numeratorRange; self.denominatorRange = denominatorRange; self.multiplier = multiplier; self.precision = precision
    }
}

/// A bounded parent list and embedded child counts. No child records are fetched.
public struct SupabaseRESTBreakdown: Codable, Equatable, Sendable {
    public var key: String
    public var title: String
    public var table: String
    public var parentKey: String?
    public var parentLabel: String?
    public var childRelation: String
    public var childTimeColumn: String?
    public var childFilters: [SupabaseRESTFilter]?
    public var parentFilters: [SupabaseRESTFilter]?
    public var parentJoins: [String]?
    public init(key: String, title: String, table: String, parentKey: String = "id", parentLabel: String? = nil, childRelation: String, childTimeColumn: String? = nil, childFilters: [SupabaseRESTFilter] = [], parentFilters: [SupabaseRESTFilter] = [], parentJoins: [String] = []) {
        self.key = key; self.title = title; self.table = table; self.parentKey = parentKey; self.parentLabel = parentLabel
        self.childRelation = childRelation; self.childTimeColumn = childTimeColumn; self.childFilters = childFilters
        self.parentFilters = parentFilters; self.parentJoins = parentJoins
    }
}

/// Uses either Supabase's restricted SQL endpoint or HEAD-only exact Data API counts.
public struct SupabaseConnector: SummaryConnector {
    public typealias Transport = HTTPConnector.Transport
    private let transport: Transport
    private static let ranges = ["24h", "7d", "30d", "lifetime"]
    public init() { transport = { request in try await HTTPConnector.fetch(request) } }
    public init(transport: @escaping Transport) { self.transport = transport }

    /// Completes a plain creation-count plan without guessing new populations.
    /// Curated catalogs stay authoritative, and the original counters stay intact.
    public static func enrichCountPlan(_ connection: ProjectConnection) throws -> ProjectConnection {
        guard connection.kind == .supabase, case .rest = try route(connection.endpoint) else { return connection }
        var decoded = try plan(connection.query)
        guard decoded.details?.isEmpty != false else { return connection }
        let definitions = connection.metrics.reduce(into: [String: String]()) { $0[$1.path] = $1.label }
        var keys = Set(decoded.metrics.map(\.key) + (decoded.ratios ?? []).map(\.key))
        var extras: [SupabaseRESTMetric] = []
        for metric in decoded.metrics {
            let creation = metric.timeColumn?.lowercased().replacingOccurrences(of: "_", with: "")
            guard metric.allTime != true, ["createdat", "insertedat", "registeredat"].contains(creation ?? "") else { continue }
            let proposed = "total_" + metric.key
            var key = proposed
            if key.count > 40 || keys.contains(key) {
                let suffix = String(MetricIdentity.uuid(projectID: connection.id, path: "supabase-total:" + metric.key).uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(6))
                key = String(proposed.prefix(33)) + "_" + suffix
            }
            guard keys.insert(key).inserted else { continue }
            var label = (definitions["metrics." + metric.key] ?? metric.label ?? ProjectSetup.friendlyLabel(metric.key)).trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["New ", "Total "] where label.lowercased().hasPrefix(prefix.lowercased()) { label = String(label.dropFirst(prefix.count)) }
            var total = metric
            total.key = key; total.label = String(("Total " + label).prefix(40)); total.allTime = true
            total.daily = false; total.notificationCounter = false; total.finiteLabel = nil
            total.counterLabel = nil; total.unitSingular = nil; total.unitPlural = nil
            extras.append(total)
        }
        guard !extras.isEmpty else { return connection }
        decoded.details = extras
        var result = connection
        result.query = try decoded.encodedQuery()
        return result
    }

    /// Catalog-only edits can retain the same counter receipts and cached base.
    /// Authentication and credential-generation checks remain the caller's job.
    public static func hasSamePrimaryCountPlan(_ old: ProjectConnection, _ new: ProjectConnection) -> Bool {
        guard old.kind == .supabase, new.kind == .supabase, old.endpoint == new.endpoint, old.metrics == new.metrics,
              let sourceRoute = try? route(old.endpoint), case .rest = sourceRoute,
              let previous = try? plan(old.query), let current = try? plan(new.query) else { return false }
        return previous.version == current.version && previous.timeZone == current.timeZone
            && previous.defaultRange == current.defaultRange && previous.metrics == current.metrics
    }

    /// Used for bounded schema metadata discovery through the restricted route.
    /// Callers keep credentials in Keychain and never use the write-capable URL.
    public func readOnlyRows(connection: ProjectConnection, secret: String?, query: String) async throws -> Data {
        guard connection.kind == .supabase, case .sql(let url) = try Self.route(connection.endpoint) else {
            throw PulseError.invalidConfiguration("Schema discovery needs the Supabase read-only query endpoint.")
        }
        try ConnectorValidation.validatePostgresQuery(query)
        var request = Self.request(url: url, token: try Self.token(secret))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, _) = try await perform(request)
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count <= 100 else {
            throw PulseError.response("Supabase returned too much schema metadata.")
        }
        return data
    }

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
            let enriched = try? DatabaseAnalytics.queryWithAnalytics(connection)
            var unavailable = connection.autoStats != nil && enriched == nil
            var row: [String: Any]
            do { row = try await sqlSummary(query: enriched ?? connection.query, endpoint: url, token: token) }
            catch {
                guard enriched != nil, enriched != connection.query, Self.canRetryBaseSummary(after: error) else { throw error }
                row = try await sqlSummary(query: connection.query, endpoint: url, token: token)
                unavailable = true
            }
            if unavailable { row["coverage"] = "Some automatic stats are unavailable. " + (row["coverage"] as? String ?? "") }
            data = try JSONSerialization.data(withJSONObject: row)
        case .rest(let url):
            let plan = try Self.plan(connection.query)
            data = try await restSummary(plan: plan, connection: connection, endpoint: url, token: token, now: now)
        }
        return try HTTPConnector.snapshot(data: data, connection: connection, now: now)
    }

    private func sqlSummary(query: String, endpoint: URL, token: String) async throws -> [String: Any] {
        var request = Self.request(url: endpoint, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (body, _) = try await perform(request)
        guard let rows = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]], rows.count == 1 else {
            throw PulseError.response("The summary query must return exactly one JSON row.")
        }
        return rows[0]
    }

    private static func canRetryBaseSummary(after error: Error) -> Bool {
        guard case PulseError.response(let message) = error else { return false }
        return [400, 404, 422, 500].contains { message == "Supabase returned HTTP \($0). Try again later." }
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
        guard query.utf8.count <= 65_536, let data = query.data(using: .utf8), let plan = try? JSONDecoder().decode(SupabaseRESTPlan.self, from: data),
              plan.version == 1, ranges.contains(plan.defaultRange), TimeZone(identifier: plan.timeZone) != nil,
              (1...3).contains(plan.metrics.count), (plan.details?.count ?? 0) <= 12,
              (plan.ratios?.count ?? 0) <= 8, (plan.breakdowns?.count ?? 0) <= 4,
              plan.coverage.map({ clean($0, limit: 500) }) ?? true else {
            throw PulseError.invalidConfiguration("Use a supported Supabase count plan with up to three headline metrics.")
        }
        let metrics = plan.metrics + (plan.details ?? [])
        let keys = metrics.map(\.key) + (plan.ratios ?? []).map(\.key)
        guard Set(keys).count == keys.count else { throw PulseError.invalidConfiguration("Give each Supabase number a unique key.") }
        for metric in metrics {
            let select = metric.select ?? "id"
            guard metricKey(metric.key), identifier(metric.table),
                  !select.isEmpty, select.count <= 300, matches(select, #"^[A-Za-z0-9_.,!():]+$"#),
                  metric.timeColumn.map(column) ?? true, metric.daily != true || metric.timeColumn != nil,
                  [metric.label, metric.finiteLabel, metric.counterLabel, metric.unitSingular, metric.unitPlural].allSatisfy({ $0.map { clean($0, limit: 40) } ?? true }) else {
                throw PulseError.invalidConfiguration("The Supabase count plan contains an unsupported table or field.")
            }
            try validateFilters(metric.filters ?? [])
        }
        let countKeys = Set(metrics.map(\.key))
        for ratio in plan.ratios ?? [] {
            guard metricKey(ratio.key), clean(ratio.label, limit: 40), countKeys.contains(ratio.numerator), countKeys.contains(ratio.denominator),
                  [ratio.numeratorRange, ratio.denominatorRange].allSatisfy({ $0.map { ranges.contains($0) } ?? true }),
                  [1.0, 100.0].contains(ratio.multiplier ?? 1), (0...4).contains(ratio.precision ?? 1) else {
                throw PulseError.invalidConfiguration("A Supabase ratio must use known, scoped counts.")
            }
        }
        guard Set((plan.breakdowns ?? []).map(\.key)).count == (plan.breakdowns?.count ?? 0) else {
            throw PulseError.invalidConfiguration("Give each Supabase grouping a unique key.")
        }
        for group in plan.breakdowns ?? [] {
            let parentKey = group.parentKey ?? "id"
            let relationParts = group.childRelation.split(separator: "!", omittingEmptySubsequences: false)
            guard metricKey(group.key), clean(group.title, limit: 80), identifier(group.table), identifier(parentKey),
                  !DatabaseAnalytics.isSensitiveIdentityColumn(parentKey),
                  group.parentLabel.map({ ["name", "display_name", "business_name", "title"].contains($0) }) ?? true,
                  (1...2).contains(relationParts.count), relationParts.allSatisfy({ identifier(String($0)) }), relationParts.last != "inner",
                  group.childTimeColumn.map(identifier) ?? true, (group.parentJoins?.count ?? 0) <= 4,
                  (group.parentJoins ?? []).allSatisfy({ matches($0, #"^[A-Za-z_][A-Za-z0-9_]{0,62}(?:![A-Za-z_][A-Za-z0-9_]{0,62})?!inner$"#) }) else {
                throw PulseError.invalidConfiguration("Use a supported parent relationship and display label for grouped numbers.")
            }
            try validateFilters(group.parentFilters ?? [])
            try validateFilters(group.childFilters ?? [])
        }
        return plan
    }

    private static func validateFilters(_ filters: [SupabaseRESTFilter]) throws {
        guard filters.count <= 12 else { throw PulseError.invalidConfiguration("Use at most twelve filters for a Supabase count.") }
        for filter in filters {
            let logic = ["and", "or"].contains(filter.column)
            let validValue = logic ? filter.value.hasPrefix("(") && filter.value.hasSuffix(")") : ["eq.", "neq.", "gt.", "gte.", "lt.", "lte.", "is.", "in.", "not."].contains(where: filter.value.hasPrefix)
            guard (logic || column(filter.column)), !["select", "limit", "offset", "order"].contains(filter.column),
                  clean(filter.value, limit: 1_024), validValue,
                  !filter.value.replacingOccurrences(of: "{{now}}", with: "").contains("{{") else {
                throw PulseError.invalidConfiguration("The Supabase count plan contains an unsupported filter.")
            }
        }
    }

    private static func metricKey(_ value: String) -> Bool { matches(value, #"^[A-Za-z][A-Za-z0-9_]{0,39}$"#) }

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
        let allMetrics = plan.metrics + (plan.details ?? [])
        var jobs: [CountJob] = []
        for metric in allMetrics {
            jobs.append(CountJob(metric: metric, range: "lifetime"))
            if metric.timeColumn != nil {
                if metric.allTime != true {
                    for (range, seconds) in [("24h", 86_400.0), ("7d", 604_800.0), ("30d", 2_592_000.0)] {
                        jobs.append(CountJob(metric: metric, range: range, lower: now.addingTimeInterval(-seconds), upper: now))
                    }
                }
                if metric.daily == true {
                    jobs.append(CountJob(metric: metric, range: "today", lower: today, upper: now))
                    jobs.append(CountJob(metric: metric, range: "yesterday", lower: yesterday, upper: today))
                }
            }
        }
        let counts = try await count(jobs: jobs, endpoint: endpoint, token: token, now: now)
        let groups = try await groupedCounts(plan.breakdowns ?? [], endpoint: endpoint, token: token, now: now)
        let definitions = connection.metrics.reduce(into: [String: String]()) { $0[$1.path] = $1.label }
        let byKey = Dictionary(uniqueKeysWithValues: allMetrics.map { ($0.key, $0) })
        func value(_ key: String, range: String) -> Int64 {
            let metric = byKey[key]!
            return counts[key + ":" + (metric.timeColumn == nil || metric.allTime == true ? "lifetime" : range)]!
        }
        func label(_ metric: SupabaseRESTMetric, range: String) -> String {
            if range != "lifetime", metric.allTime != true, let label = metric.finiteLabel { return label }
            return metric.label ?? definitions["metrics." + metric.key] ?? ProjectSetup.friendlyLabel(metric.key)
        }
        func payload(_ range: String) -> [String: Any] {
            var values: [String: Int64] = [:]
            var labels: [String: String] = [:]
            for metric in plan.metrics {
                values[metric.key] = value(metric.key, range: range)
                labels["metrics." + metric.key] = label(metric, range: range)
            }
            var details: [[String: Any]] = (plan.details ?? []).map { metric in
                ["id": "supabase:" + metric.key, "label": label(metric, range: range), "value": value(metric.key, range: range)]
            }
            for ratio in plan.ratios ?? [] {
                let numerator = value(ratio.numerator, range: ratio.numeratorRange ?? range)
                let denominator = value(ratio.denominator, range: ratio.denominatorRange ?? range)
                let formatted: String
                if denominator == 0 { formatted = "—" }
                else {
                    let result = Decimal(numerator) / Decimal(denominator) * Decimal(ratio.multiplier ?? 1)
                    let formatter = NumberFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.numberStyle = .decimal
                    formatter.maximumFractionDigits = ratio.precision ?? 1
                    formatted = formatter.string(from: NSDecimalNumber(decimal: result)) ?? "—"
                }
                details.append(["id": "supabase:" + ratio.key, "label": ratio.label, "value": formatted])
            }
            let selectedGroups = (plan.breakdowns ?? []).compactMap { definition in
                groups[definition.key + ":" + (definition.childTimeColumn == nil ? "lifetime" : range)]
            }
            let breakdowns: [[String: Any]] = selectedGroups.filter { !$0.rows.isEmpty }.map { group in
                ["id": "supabase:" + group.key, "title": group.title,
                 "rows": group.rows.map { ["id": $0.id, "label": $0.label, "value": $0.value] }, "truncated": group.truncated]
            }
            var result: [String: Any] = ["metrics": values, "labels": labels, "__pulse_details": details, "__pulse_breakdowns": breakdowns]
            let omission = selectedGroups.contains { $0.omittedForLimit } ? "Grouped lists above 100 items are omitted. " : ""
            if !omission.isEmpty || plan.coverage != nil { result["coverage"] = omission + (plan.coverage ?? "") }
            return result
        }
        var result = payload(plan.defaultRange)
        result["ranges"] = Dictionary(uniqueKeysWithValues: Self.ranges.map { ($0, payload($0)) })
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: now)
        let day = String(format: "%04d-%02d-%02d", dayComponents.year!, dayComponents.month!, dayComponents.day!)
        var counters: [[String: Any]] = [], daily: [[String: Any]] = []
        for metric in allMetrics {
            let label = metric.counterLabel ?? metric.label ?? definitions["metrics." + metric.key] ?? ProjectSetup.friendlyLabel(metric.key)
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

    private struct CountRequest: Sendable {
        var url: URL
        var identities: [String]
    }

    private func count(jobs: [CountJob], endpoint: URL, token: String, now: Date) async throws -> [String: Int64] {
        var requests: [CountRequest] = []
        var indices: [String: Int] = [:]
        for job in jobs {
            var items = [URLQueryItem(name: "select", value: job.metric.select ?? "id")]
            items += Self.filterItems(job.metric.filters ?? [], now: now)
            if let column = job.metric.timeColumn, let lower = job.lower { items.append(URLQueryItem(name: column, value: "gte." + Self.iso(lower))) }
            if let column = job.metric.timeColumn, let upper = job.upper { items.append(URLQueryItem(name: column, value: "lt." + Self.iso(upper))) }
            let url = Self.url(endpoint: endpoint, table: job.metric.table, items: items)
            if let index = indices[url.absoluteString] { requests[index].identities.append(job.identity) }
            else { indices[url.absoluteString] = requests.count; requests.append(CountRequest(url: url, identities: [job.identity])) }
        }
        return try await withThrowingTaskGroup(of: ([String], Int64).self) { group in
            var next = 0, values: [String: Int64] = [:]
            func enqueue(_ item: CountRequest) {
                group.addTask {
                    try Task.checkCancellation()
                    var request = Self.request(url: item.url, token: token)
                    request.httpMethod = "HEAD"
                    request.setValue(token, forHTTPHeaderField: "apikey")
                    request.setValue("count=exact", forHTTPHeaderField: "Prefer")
                    request.setValue("0-0", forHTTPHeaderField: "Range")
                    request.setValue("items", forHTTPHeaderField: "Range-Unit")
                    let (_, response) = try await perform(request)
                    return (item.identities, try Self.exactCount(response))
                }
            }
            while next < min(3, requests.count) { enqueue(requests[next]); next += 1 }
            while let (identities, value) = try await group.next() {
                for identity in identities { values[identity] = value }
                if next < requests.count { enqueue(requests[next]); next += 1 }
            }
            return values
        }
    }

    private struct GroupJob: Sendable {
        var definition: SupabaseRESTBreakdown
        var range: String
        var lower: Date?
        var upper: Date?
        var identity: String { definition.key + ":" + range }
    }
    private struct GroupResult: Sendable {
        var key: String
        var title: String
        var rows: [MetricBreakdownRow]
        var truncated: Bool
        var omittedForLimit = false
    }
    private func groupedCounts(_ definitions: [SupabaseRESTBreakdown], endpoint: URL, token: String, now: Date) async throws -> [String: GroupResult] {
        var jobs: [GroupJob] = []
        for definition in definitions {
            jobs.append(GroupJob(definition: definition, range: "lifetime"))
            if definition.childTimeColumn != nil {
                for (range, seconds) in [("24h", 86_400.0), ("7d", 604_800.0), ("30d", 2_592_000.0)] {
                    jobs.append(GroupJob(definition: definition, range: range, lower: now.addingTimeInterval(-seconds), upper: now))
                }
            }
        }
        return try await withThrowingTaskGroup(of: (String, GroupResult).self) { group in
            var next = 0, results: [String: GroupResult] = [:]
            func enqueue(_ job: GroupJob) {
                group.addTask {
                    try Task.checkCancellation()
                    let definition = job.definition
                    let parentKey = definition.parentKey ?? "id"
                    var fields = [parentKey]
                    if let label = definition.parentLabel, label != parentKey { fields.append(label) }
                    fields.append("pulse_count:" + definition.childRelation + "(count)")
                    fields += (definition.parentJoins ?? []).map { $0 + "()" }
                    var items = [URLQueryItem(name: "select", value: fields.joined(separator: ",")),
                                 URLQueryItem(name: "order", value: parentKey + ".asc"), URLQueryItem(name: "limit", value: "100")]
                    items += Self.filterItems(definition.parentFilters ?? [], now: now)
                    items += Self.filterItems(definition.childFilters ?? [], prefix: "pulse_count.", now: now)
                    if let column = definition.childTimeColumn, let lower = job.lower { items.append(URLQueryItem(name: "pulse_count." + column, value: "gte." + Self.iso(lower))) }
                    if let column = definition.childTimeColumn, let upper = job.upper { items.append(URLQueryItem(name: "pulse_count." + column, value: "lt." + Self.iso(upper))) }
                    var request = Self.request(url: Self.url(endpoint: endpoint, table: definition.table, items: items), token: token)
                    request.httpMethod = "GET"
                    request.setValue(token, forHTTPHeaderField: "apikey")
                    request.setValue("count=exact", forHTTPHeaderField: "Prefer")
                    request.setValue("0-99", forHTTPHeaderField: "Range")
                    request.setValue("items", forHTTPHeaderField: "Range-Unit")
                    let (body, response) = try await perform(request)
                    let total = try Self.exactCount(response)
                    // A bounded prefix cannot establish the highest counts globally.
                    // Keep the exact aggregate KPIs, but omit this optional list.
                    if total > 100 { return (job.identity, GroupResult(key: definition.key, title: definition.title, rows: [], truncated: true, omittedForLimit: true)) }
                    guard let rows = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]], rows.count == Int(total) else {
                        throw PulseError.response("Supabase returned an incomplete grouped count. Check the relationship permissions.")
                    }
                    var seen: Set<String> = []
                    var parsed: [(MetricBreakdownRow, Int64)] = []
                    for row in rows {
                        let id: String
                        if let value = row[parentKey] as? String, !value.isEmpty, value.count <= 200 { id = value }
                        else if let value = Self.exactInteger(row[parentKey]) { id = String(value) }
                        else { throw PulseError.response("Supabase returned an unsupported grouping identity.") }
                        let aggregate: [String: Any]?
                        if let nested = row["pulse_count"] as? [[String: Any]], nested.count == 1 { aggregate = nested[0] }
                        else { aggregate = row["pulse_count"] as? [String: Any] }
                        guard seen.insert(id).inserted, let count = Self.nonnegativeInteger(aggregate?["count"]) else {
                            throw PulseError.response("Supabase did not return an exact grouped count.")
                        }
                        let fallback = ProjectSetup.friendlyLabel(definition.table) + " " + String(id.prefix(8))
                        let label = (definition.parentLabel.flatMap { row[$0] as? String }).flatMap { Self.clean($0, limit: 80) ? $0 : nil } ?? fallback
                        parsed.append((MetricBreakdownRow(id: id, label: label, value: String(count)), count))
                    }
                    parsed.sort { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }
                    return (job.identity, GroupResult(key: definition.key, title: definition.title, rows: parsed.prefix(10).map(\.0), truncated: total > 10))
                }
            }
            while next < min(3, jobs.count) { enqueue(jobs[next]); next += 1 }
            while let (identity, result) = try await group.next() {
                results[identity] = result
                if next < jobs.count { enqueue(jobs[next]); next += 1 }
            }
            return results
        }
    }

    private static func filterItems(_ filters: [SupabaseRESTFilter], prefix: String = "", now: Date) -> [URLQueryItem] {
        filters.map { URLQueryItem(name: prefix + $0.column, value: $0.value.replacingOccurrences(of: "{{now}}", with: iso(now))) }
    }
    private static func url(endpoint: URL, table: String, items: [URLQueryItem]) -> URL {
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        parts.path = "/rest/v1/" + table
        parts.queryItems = items.sorted { $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name }
        return parts.url!
    }
    private static func exactCount(_ response: HTTPURLResponse) throws -> Int64 {
        guard let contentRange = response.value(forHTTPHeaderField: "Content-Range"), matches(contentRange, #"^(?:[0-9]+-[0-9]+|\*)/[0-9]+$"#),
              let total = contentRange.split(separator: "/", omittingEmptySubsequences: false).last,
              !total.isEmpty, total.allSatisfy(\.isASCII), total.allSatisfy(\.isNumber), let value = Int64(total), value >= 0 else {
            throw PulseError.response("Supabase did not return an exact count. Check the table and count permissions.")
        }
        return value
    }
    private static func nonnegativeInteger(_ value: Any?) -> Int64? {
        guard let count = exactInteger(value), count >= 0 else { return nil }
        return count
    }
    private static func exactInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int64(number.stringValue)
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
