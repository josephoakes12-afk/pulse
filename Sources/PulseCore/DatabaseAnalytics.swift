import Foundation

/// A small structural plan. It never guesses joins from similarly named columns.
public enum DatabaseAnalytics {
    public static func eligibleRelationships(_ relationships: [DatabaseRelationship], tables: [DatabaseTable]) -> [DatabaseRelationship] {
        let selected = Set(tables.map(\.id))
        // The child metric is enough to make its parent grouping useful. The
        // parent need not occupy one of the three headline positions; discovery
        // has already checked that both tables are readable.
        let matching = relationships.filter { selected.contains($0.child.id) && $0.child.id != $0.parent.id }
        let grouped = Dictionary(grouping: matching, by: { $0.child.id + "→" + $0.parent.id })
        // Two links to the same parent can mean creator, customer, assignee, etc.
        // Do not choose one just because its column name looks plausible.
        return grouped.values.compactMap { rows -> DatabaseRelationship? in
            let distinct = rows.reduce(into: [DatabaseRelationship]()) { result, row in if !result.contains(row) { result.append(row) } }
            return distinct.count == 1 ? distinct.first : nil
        }.sorted { relationshipID($0) < relationshipID($1) }
    }

    public static func configure(base: ProjectConnection, tables: [DatabaseTable], relationships: [DatabaseRelationship], columns: [DatabaseColumn] = []) -> ProjectConnection {
        var result = base
        let eligible = eligibleRelationships(relationships, tables: tables)
        let old = (base.autoStats?.relationships ?? []).map(relationshipID)
        let ordered = eligible.sorted {
            let leftOld = old.firstIndex(of: relationshipID($0)), rightOld = old.firstIndex(of: relationshipID($1))
            if leftOld != nil || rightOld != nil { return (leftOld ?? Int.max) < (rightOld ?? Int.max) }
            let left = discoveryPriority($0), right = discoveryPriority($1)
            return left == right ? relationshipID($0) < relationshipID($1) : left < right
        }
        let selected = Set(tables.map(\.id))
        let candidates = columns.filter {
            selected.contains($0.table.id) && !isSensitiveIdentityColumn($0.name) && validColumn($0)
        }
        let safeColumns = tables.prefix(3).flatMap { table in
            let found = candidates.filter { $0.table.id == table.id }
            return Array(found.filter { $0.kind == .timestamp }.prefix(1))
                + Array(found.filter { $0.kind == .boolean }.prefix(2))
                + Array(found.filter { $0.kind == .enumeration }.prefix(1))
        }
        result.autoStats = ordered.isEmpty && safeColumns.isEmpty ? nil : DatabaseAnalyticsPlan(relationships: Array(ordered.prefix(4)), version: 2, columns: safeColumns.isEmpty ? nil : safeColumns)
        return result
    }

    public static func recommendedTables(from relationships: [DatabaseRelationship]) -> [DatabaseTable] {
        let childNames: Set<String> = ["bookings", "appointments", "reservations", "games", "sessions", "orders", "article_reads", "reads"]
        let parentNames: Set<String> = ["users", "businesses", "customers", "clients", "players", "readers", "accounts", "profiles", "venues", "shops"]
        let allTables = relationships.flatMap { [$0.child, $0.parent] }
        let eligible = eligibleRelationships(relationships, tables: allTables)
        let publicPairs = eligible.filter { $0.child.schema == "public" && $0.parent.schema == "public" }
        let candidates = publicPairs.isEmpty ? eligible : publicPairs
        // Familiar names can improve a default, but they are not an allowlist:
        // a single declared deployments→projects or messages→teams relationship
        // is just as usable. Several plausible unknown pairs need a selection.
        let familiar = candidates.filter {
            childNames.contains($0.child.name.lowercased()) && parentNames.contains($0.parent.name.lowercased())
        }
        let preferred = familiar.count == 1 ? familiar : candidates
        guard preferred.count == 1, let relationship = preferred.first else { return [] }
        return [relationship.parent, relationship.child]
    }

    public static func queryWithAnalytics(_ connection: ProjectConnection) throws -> String {
        guard let plan = connection.autoStats else { return connection.query }
        if plan.version == 2 { return try expandedQuery(connection, plan: plan) }
        guard plan.version == 1, (1...2).contains(plan.relationships.count) else {
            throw PulseError.invalidConfiguration("This automatic stats setup isn’t supported.")
        }
        let allTables = plan.relationships.flatMap { [$0.child, $0.parent] }
        let eligible = eligibleRelationships(plan.relationships, tables: allTables)
        guard eligible.count == plan.relationships.count else { throw PulseError.invalidConfiguration("These table relationships need to be checked again.") }
        let analyses = try plan.relationships.enumerated().map { try analysisSQL($0.element, index: $0.offset) }
        let joins = analyses.enumerated().map { "CROSS JOIN (\($0.element)) AS pulse_analysis_\($0.offset)" }.joined(separator: "\n")
        let detailArrays = analyses.indices.map { "pulse_analysis_\($0).details" }.joined(separator: " || ")
        let breakdownArrays = analyses.indices.map { "jsonb_build_array(pulse_analysis_\($0).breakdown)" }.joined(separator: " || ")
        return """
        SELECT pulse_base.*, (\(detailArrays)) AS __pulse_details,
               (\(breakdownArrays)) AS __pulse_breakdowns
        FROM (\(connection.query)) AS pulse_base
        \(joins)
        """
    }

    public static func relationshipID(_ relationship: DatabaseRelationship) -> String {
        relationship.child.id + ":" + relationship.childColumn + "→" + relationship.parent.id + ":" + relationship.parentColumn
    }

    static func discoveryPriority(_ relationship: DatabaseRelationship) -> Int {
        ["bookings", "appointments", "reservations", "games", "orders", "sessions", "reads", "article_reads"].contains(relationship.child.name.lowercased()) ? 0 : 1
    }

    private static func analysisSQL(_ relationship: DatabaseRelationship, index: Int, expanded: Bool = false) throws -> String {
        guard !isSensitiveIdentityColumn(relationship.parentColumn) else {
            throw PulseError.invalidConfiguration("This relationship uses a private contact or credential field as its identity.")
        }
        let child = try tableSQL(relationship.child)
        let parent = try tableSQL(relationship.parent)
        let foreignKey = try identifier(relationship.childColumn)
        let parentKey = try identifier(relationship.parentColumn)
        let parentName = singular(ProjectSetup.friendlyLabel(relationship.parent.name))
        let children = ProjectSetup.friendlyLabel(relationship.child.name)
        let childLabel = children.lowercased()
        let parentLabel = parentName.lowercased()
        let identity = "relationship_\(index)"
        let fallbackLabel = literal(parentName + " ") + " || left(p.\(parentKey)::text, 8)"
        let displayLabel: String
        if let labelColumn = relationship.parentLabelColumn {
            guard ["name", "display_name", "business_name", "title"].contains(labelColumn) else {
                throw PulseError.invalidConfiguration("This automatic stats label isn’t supported.")
            }
            displayLabel = "COALESCE(NULLIF(btrim(p.\(try identifier(labelColumn))::text), ''), \(fallbackLabel))"
        } else { displayLabel = fallbackLabel }
        let averageLabel = String(("Avg. " + childLabel + " / " + parentLabel).prefix(40))
        let activeLabel = String((ProjectSetup.friendlyLabel(relationship.parent.name) + " with " + childLabel).prefix(40))
        let unlinkedLabel = String(("Unlinked " + childLabel).prefix(40))
        let title = String((children + " by " + parentLabel).prefix(60))
        let stableID = "relationship:" + relationshipID(relationship)
        let extraDetails = expanded ? """
        , jsonb_build_object('id', \(literal("table:" + relationship.parent.id + ".total")), 'label', \(literal(totalLabel(parentName: ProjectSetup.friendlyLabel(relationship.parent.name)))), 'value', parents::text),
          jsonb_build_object('id', \(literal("table:" + relationship.child.id + ".total")), 'label', \(literal(totalLabel(parentName: children))), 'value', all_children::text),
          jsonb_build_object('id', \(literal(stableID + ".without")), 'label', \(literal(lifetimeLabel(ProjectSetup.friendlyLabel(relationship.parent.name) + " without " + childLabel))), 'value', (parents - active)::text),
          jsonb_build_object('id', \(literal(stableID + ".maximum")), 'label', \(literal(lifetimeLabel("Max. " + childLabel + " / " + parentLabel))), 'value', maximum::text),
          jsonb_build_object('id', \(literal(stableID + ".coverage")), 'label', \(literal(lifetimeLabel(ProjectSetup.friendlyLabel(relationship.parent.name) + " with " + childLabel + " %"))),
              'value', CASE WHEN parents > 0 THEN round(active::numeric * 100 / parents, 1)::text || '%' ELSE '—' END)
        """ : ""
        return """
        WITH pulse_child_counts AS (
            SELECT c.\(foreignKey) AS parent_id, count(*)::bigint AS quantity
            FROM \(child) AS c GROUP BY c.\(foreignKey)
        ), pulse_parent_counts AS (
            SELECT p.\(parentKey)::text AS id, left(\(displayLabel), 80) AS label,
                   COALESCE(c.quantity, 0)::bigint AS quantity
            FROM \(parent) AS p
            LEFT JOIN pulse_child_counts AS c ON c.parent_id = p.\(parentKey)
        ), pulse_totals AS (
            SELECT count(*)::bigint AS parents,
                   count(*) FILTER (WHERE quantity > 0)::bigint AS active,
                   COALESCE(sum(quantity), 0)::bigint AS linked,
                   \(expanded ? "COALESCE(max(quantity), 0)::bigint AS maximum," : "")
                   (SELECT COALESCE(sum(quantity), 0)::bigint FROM pulse_child_counts) AS all_children
            FROM pulse_parent_counts
        ), pulse_top AS (
            SELECT id, label, quantity FROM pulse_parent_counts
            ORDER BY quantity DESC, id LIMIT 10
        )
        SELECT jsonb_build_array(
            jsonb_build_object('id', \(literal(identity + ".average")), 'label', \(literal(averageLabel)),
                'value', CASE WHEN parents > 0 THEN round(linked::numeric / parents, 1)::text ELSE '—' END),
            jsonb_build_object('id', \(literal(identity + ".active")), 'label', \(literal(activeLabel)), 'value', active::text),
            jsonb_build_object('id', \(literal(identity + ".unlinked")), 'label', \(literal(unlinkedLabel)),
                'value', (all_children - linked)::text)
            \(extraDetails)
        ) AS details,
        jsonb_build_object('id', \(literal(identity)), 'title', \(literal(title)),
            'rows', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', id, 'label', label, 'value', quantity::text)
                                ORDER BY quantity DESC, id) FROM pulse_top), '[]'::jsonb),
            'truncated', parents > 10) AS breakdown
        FROM pulse_totals
        """
    }

    /// One metadata query, bounded to selected readable tables. No source values
    /// are sampled; only built-in booleans, declared enums and creation instants.
    public static func columnDiscoveryQuery(tables: [DatabaseTable]) throws -> String {
        guard (1...100).contains(tables.count) else { throw PulseError.invalidConfiguration("Choose at most 100 tables to inspect.") }
        let identities = try tables.map { table in
            _ = try identifier(table.schema); _ = try identifier(table.name)
            return "(" + literal(table.schema) + ", " + literal(table.name) + ")"
        }.joined(separator: ", ")
        return """
        SELECT json_build_object(
            'table', json_build_object('schema', n.nspname, 'name', c.relname, 'isView', c.relkind IN ('v', 'm')),
            'name', a.attname,
            'kind', CASE WHEN t.typtype = 'e' THEN 'enumeration' WHEN t.typname = 'bool' THEN 'boolean' ELSE 'timestamp' END,
            'enumValues', COALESCE((SELECT json_agg(e.enumlabel ORDER BY e.enumsortorder)
                                   FROM pg_catalog.pg_enum e WHERE e.enumtypid = t.oid), '[]'::json)
        )::text AS pulse_column
        FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
        JOIN pg_catalog.pg_namespace tn ON tn.oid = t.typnamespace
        WHERE a.attnum > 0 AND NOT a.attisdropped AND c.relkind IN ('r', 'p', 'v', 'm')
          AND (n.nspname, c.relname) IN (\(identities))
          AND pg_catalog.has_schema_privilege(n.oid, 'USAGE')
          AND pg_catalog.has_table_privilege(c.oid, 'SELECT')
          AND pg_catalog.has_column_privilege(c.oid, a.attnum, 'SELECT')
          AND lower(a.attname) !~ '(email|phone|mobile|address|password|passwd|secret|token|credential|signature|api.?key|account.?number|social.?security|ssn)'
          AND ((tn.nspname = 'pg_catalog' AND t.typname = 'bool')
               OR (tn.nspname = 'pg_catalog' AND t.typname = 'timestamptz'
                   AND a.attname IN ('created_at', 'inserted_at', 'registered_at', 'date_created'))
               OR (t.typtype = 'e' AND (SELECT count(*) FROM pg_catalog.pg_enum e WHERE e.enumtypid = t.oid) BETWEEN 1 AND 8))
        ORDER BY CASE WHEN n.nspname = 'public' THEN 0 ELSE 1 END, n.nspname, c.relname,
                 CASE WHEN t.typname = 'timestamptz' THEN 0 WHEN t.typname = 'bool' THEN 1 ELSE 2 END, a.attnum
        LIMIT 48
        """
    }

    private static func expandedQuery(_ connection: ProjectConnection, plan: DatabaseAnalyticsPlan) throws -> String {
        let columns = plan.columns ?? []
        guard plan.relationships.count <= 4, columns.count <= 12,
              !plan.relationships.isEmpty || !columns.isEmpty,
              columns.allSatisfy({ validColumn($0) && !isSensitiveIdentityColumn($0.name) }),
              Set(columns.map { $0.table.id + ":" + $0.name }).count == columns.count else {
            throw PulseError.invalidConfiguration("This automatic stats setup isn’t supported.")
        }
        let allTables = plan.relationships.flatMap { [$0.child, $0.parent] }
        guard eligibleRelationships(plan.relationships, tables: allTables).count == plan.relationships.count else {
            throw PulseError.invalidConfiguration("These table relationships need to be checked again.")
        }
        var analyses: [String] = []
        var details: [String] = []
        var breakdowns: [String] = []
        for (index, relationship) in plan.relationships.enumerated() {
            let alias = "pulse_relationship_\(index)"
            analyses.append("CROSS JOIN (\(try analysisSQL(relationship, index: index, expanded: true))) AS \(alias)")
            details.append("\(alias).details")
            breakdowns.append("jsonb_build_array(\(alias).breakdown)")
        }
        let selected = connection.sourceTables ?? columns.reduce(into: [DatabaseTable]()) { result, column in
            if !result.contains(column.table) { result.append(column.table) }
        }
        guard selected.count <= 3, columns.allSatisfy({ column in selected.contains { $0.id == column.table.id } }) else {
            throw PulseError.invalidConfiguration("These automatic table statistics need to be checked again.")
        }
        for (index, table) in selected.enumerated() {
            let metadata = columns.filter { $0.table.id == table.id }
            guard !metadata.isEmpty else { continue }
            let alias = "pulse_table_\(index)"
            analyses.append("CROSS JOIN (\(try tableAnalysisSQL(table, columns: metadata))) AS \(alias)")
            details.append("\(alias).details")
            breakdowns.append("\(alias).breakdowns")
        }
        guard !details.isEmpty else { throw PulseError.invalidConfiguration("No automatic statistics are available for these tables.") }
        // Round-robin the useful first measures from every selected source before
        // advanced extras, with a fixed payload cap regardless of schema size.
        let bounded = """
        (SELECT COALESCE(jsonb_agg(pulse_item ORDER BY item_position, group_position), '[]'::jsonb)
         FROM (
             SELECT pulse_item, item_position, group_position
             FROM (
                 SELECT DISTINCT ON (pulse_item->>'id') pulse_item, item_position, group_position
                 FROM jsonb_array_elements(jsonb_build_array(\(details.joined(separator: ", ")))) WITH ORDINALITY AS source_groups(source_group, group_position)
                 CROSS JOIN LATERAL jsonb_array_elements(source_group) WITH ORDINALITY AS source_items(pulse_item, item_position)
                 ORDER BY pulse_item->>'id', item_position, group_position
             ) AS pulse_unique_candidates
             ORDER BY item_position, group_position LIMIT 24
         ) AS pulse_catalog)
        """
        return """
        SELECT pulse_base.*, \(bounded) AS __pulse_details,
               (\(breakdowns.joined(separator: " || "))) AS __pulse_breakdowns
        FROM (\(connection.query)) AS pulse_base
        \(analyses.joined(separator: "\n"))
        """
    }

    private static func tableAnalysisSQL(_ table: DatabaseTable, columns: [DatabaseColumn]) throws -> String {
        let tableName = ProjectSetup.friendlyLabel(table.name)
        let alias = "pulse_counts"
        var aggregates = ["count(*)::bigint AS total"]
        var entries = [detail(id: "table:" + table.id + ".total", label: totalLabel(parentName: tableName), value: "\(alias).total::text")]
        var enumGroups: [String] = []
        var nextIndex = 0
        for column in columns {
            let field = try identifier(column.name)
            let columnID = "table:" + table.id + ":" + column.name
            let columnLabel = ProjectSetup.friendlyLabel(column.name)
            switch column.kind {
            case .timestamp:
                for (range, interval) in [("24h", "24 hours"), ("7d", "168 hours"), ("30d", "720 hours")] {
                    let key = "value_\(nextIndex)"; nextIndex += 1
                    aggregates.append("count(*) FILTER (WHERE c.\(field) >= CURRENT_TIMESTAMP - interval \(literal(interval)) AND c.\(field) <= CURRENT_TIMESTAMP)::bigint AS \(key)")
                    entries.append(detail(id: columnID + ".new." + range, label: String(("New " + tableName.lowercased()).prefix(32)) + " · " + range, value: "\(alias).\(key)::text"))
                }
            case .boolean:
                for (suffix, condition) in [("yes", "IS TRUE"), ("no", "IS FALSE")] {
                    let key = "value_\(nextIndex)"; nextIndex += 1
                    aggregates.append("count(*) FILTER (WHERE c.\(field) \(condition))::bigint AS \(key)")
                    entries.append(detail(id: columnID + "." + suffix, label: lifetimeLabel(tableName + " · " + columnLabel + " " + suffix), value: "\(alias).\(key)::text"))
                }
            case .enumeration:
                var rows: [String] = []
                for value in column.enumValues {
                    let key = "value_\(nextIndex)"; nextIndex += 1
                    aggregates.append("count(*) FILTER (WHERE c.\(field)::text = \(literal(value)))::bigint AS \(key)")
                    entries.append(detail(id: columnID + ".enum:" + value, label: lifetimeLabel(tableName + " · " + value), value: "\(alias).\(key)::text"))
                    rows.append("jsonb_build_object('id', \(literal(value)), 'label', \(literal(value)), 'value', \(alias).\(key)::text)")
                }
                enumGroups.append("jsonb_build_object('id', \(literal(columnID + ".distribution")), 'title', \(literal(String((tableName + " by " + columnLabel.lowercased() + " · total").prefix(60)))), 'rows', jsonb_build_array(\(rows.joined(separator: ", "))), 'truncated', false)")
            }
        }
        return """
        SELECT jsonb_build_array(\(entries.joined(separator: ",\n"))) AS details,
               jsonb_build_array(\(enumGroups.joined(separator: ", "))) AS breakdowns
        FROM (SELECT \(aggregates.joined(separator: ", ")) FROM \(try tableSQL(table)) AS c) AS \(alias)
        """
    }

    private static func detail(id: String, label: String, value: String) -> String {
        "jsonb_build_object('id', \(literal(id)), 'label', \(literal(label)), 'value', \(value))"
    }

    private static func validColumn(_ column: DatabaseColumn) -> Bool {
        guard (try? identifier(column.name)) != nil, (try? tableSQL(column.table)) != nil else { return false }
        switch column.kind {
        case .timestamp:
            return ["created_at", "inserted_at", "registered_at", "date_created"].contains(column.name) && column.enumValues.isEmpty
        case .boolean: return column.enumValues.isEmpty
        case .enumeration:
            return (1...8).contains(column.enumValues.count) && Set(column.enumValues).count == column.enumValues.count
                && column.enumValues.allSatisfy { !$0.isEmpty && $0.utf8.count <= 80 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
        }
    }

    static func identifier(_ value: String) throws -> String {
        let controls = CharacterSet.controlCharacters
        guard !value.isEmpty, value.utf8.count <= 63, !value.unicodeScalars.contains(where: { controls.contains($0) }) else {
            throw PulseError.invalidConfiguration("A selected table or column name isn’t supported.")
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func literal(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''")
        return (value.contains("\\") ? "E'" : "'") + escaped + "'"
    }
    private static func totalLabel(parentName: String) -> String { "Total " + String(parentName.lowercased().prefix(34)) }
    private static func lifetimeLabel(_ value: String) -> String { String(value.prefix(32)) + " · total" }
    static func isSensitiveIdentityColumn(_ value: String) -> Bool {
        let normalized = value.lowercased().filter { $0.isLetter || $0.isNumber }
        return ["email", "phone", "mobile", "address", "password", "passwd", "secret", "token", "credential", "signature", "apikey", "accountnumber", "socialsecurity", "ssn"].contains { normalized.contains($0) }
    }
    private static func tableSQL(_ table: DatabaseTable) throws -> String { try identifier(table.schema) + "." + identifier(table.name) }
    private static func singular(_ word: String) -> String {
        if let irregular = ["people": "Person", "children": "Child"][word.lowercased()] { return irregular }
        if word.lowercased().hasSuffix("businesses") { return String(word.dropLast(2)) }
        if word.lowercased().hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.lowercased().hasSuffix("s"), !word.lowercased().hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }
}
