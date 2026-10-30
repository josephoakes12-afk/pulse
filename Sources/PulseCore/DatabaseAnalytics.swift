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

    public static func configure(base: ProjectConnection, tables: [DatabaseTable], relationships: [DatabaseRelationship]) -> ProjectConnection {
        var result = base
        let eligible = eligibleRelationships(relationships, tables: tables)
        result.autoStats = eligible.isEmpty ? nil : DatabaseAnalyticsPlan(relationships: Array(eligible.prefix(2)))
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

    private static func analysisSQL(_ relationship: DatabaseRelationship, index: Int) throws -> String {
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
        ) AS details,
        jsonb_build_object('id', \(literal(identity)), 'title', \(literal(title)),
            'rows', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', id, 'label', label, 'value', quantity::text)
                                ORDER BY quantity DESC, id) FROM pulse_top), '[]'::jsonb),
            'truncated', parents > 10) AS breakdown
        FROM pulse_totals
        """
    }

    static func identifier(_ value: String) throws -> String {
        let controls = CharacterSet.controlCharacters
        guard !value.isEmpty, value.utf8.count <= 63, !value.unicodeScalars.contains(where: { controls.contains($0) }) else {
            throw PulseError.invalidConfiguration("A selected table or column name isn’t supported.")
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func literal(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
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
