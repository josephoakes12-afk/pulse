import AppKit
import Combine
import Foundation
import PulseCore
import PulseWidgetData
import UserNotifications

enum MetricPlacement { case headline, drawer }

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()
    @Published private(set) var connections: [ProjectConnection] = []
    @Published private(set) var snapshots: [UUID: ProjectSnapshot] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var refreshing: Set<UUID> = []
    @Published private(set) var recentEvents: [UUID: [PulseEvent]] = [:]
    @Published private(set) var metricVisibilities: [UUID: MetricVisibility] = [:]
    @Published private(set) var cloudSyncStatus = PrivateCloudSyncStatus()
    @Published private(set) var cloudSummary: WidgetSnapshot?
    @Published var widgetFocusProjectID: UUID?
    @Published var storageError: String?
    @Published var showExamples: Bool = true
    @Published private(set) var selectedRange: MetricTimeRange = .last7Days
    @Published private var demoProjects = DemoData.projects
    private var storage: LocalStore?
    private var viewStateURL: URL?
    private let credentials = CredentialStore()
    private var timer: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var lastAttempts: [UUID: Date] = [:]
    private var started = false
    private var isMutating = false
    private var inspectedConnections: Set<String> = []
    private var pendingRangeReveals: [UUID: MetricTimeRange] = [:]
    private var visibilityWrites: [UUID: (id: UUID, task: Task<Void, Error>)] = [:]
    private var widgetBridge: WidgetBridge?
    private var cloudSyncBridge: PrivateCloudSyncController?
    private var dataDirectoryURL: URL?

    var isDemo: Bool { connections.isEmpty && cloudSummary == nil && showExamples }
    var isCloudReceiver: Bool { connections.isEmpty && cloudSummary != nil }
    var cloudProjects: [WidgetProject] {
        cloudSummary?.projects.filter { $0.enabled && $0.range(rawValue: selectedRange.rawValue) != nil } ?? []
    }
    var displayedConnections: [ProjectConnection] {
        if isDemo { return demoProjects }
        return connections.filter { isVisibleInSelectedRange($0) }
    }
    var unavailableConnections: [ProjectConnection] {
        isDemo ? [] : connections.filter { !isVisibleInSelectedRange($0) }
    }
    var isRefreshing: Bool { !refreshing.isEmpty }

    private func isVisibleInSelectedRange(_ connection: ProjectConnection) -> Bool {
        // A pending or failed collection must remain visible. Hide only a
        // successfully measured source that explicitly cannot supply this range.
        guard errors[connection.id] == nil, let snapshot = snapshots[connection.id] else { return true }
        return snapshot.supports(selectedRange)
    }

    init() {
        do {
            let arguments = ProcessInfo.processInfo.arguments
            let directory: URL
            if let index = arguments.firstIndex(of: "--data-directory"), arguments.indices.contains(index + 1) {
                directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            } else {
                directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent(arguments.contains("--demo") ? "Pulse Demo" : "Pulse", isDirectory: true)
            }
            storage = try LocalStore(databaseURL: directory.appendingPathComponent("pulse.sqlite"))
            dataDirectoryURL = directory
            viewStateURL = directory.appendingPathComponent("view-state.json")
            if let viewStateURL, let data = try? Data(contentsOf: viewStateURL),
               let saved = try? JSONDecoder().decode([String: String].self, from: data),
               let range = saved["range"].flatMap(MetricTimeRange.init(rawValue:)) { selectedRange = range }
        } catch { storageError = "Pulse couldn’t open its local storage. \(error.localizedDescription)" }
    }

    func start() async {
        guard !started, let storage else { return }
        started = true
        do {
            connections = try await storage.loadConnections()
            metricVisibilities = try await storage.loadMetricVisibility()
            snapshots = Dictionary(uniqueKeysWithValues: try await storage.loadSnapshots().map { ($0.projectID, $0) })
            await loadEvents()
        } catch { storageError = error.localizedDescription }
        if ProcessInfo.processInfo.arguments.contains("--empty") { showExamples = false }
        if ProcessInfo.processInfo.arguments.contains("--demo") { connections = []; snapshots = [:]; showExamples = true }
        widgetBridge = WidgetBridge(app: self)
        if let directory = dataDirectoryURL {
            cloudSyncBridge = PrivateCloudSyncController(app: self, directory: directory)
            if ProcessInfo.processInfo.arguments.contains("--enable-icloud-sync") {
                Task { await cloudSyncBridge?.setEnabled(true) }
            }
        }
        if connections.contains(where: \.notificationsEnabled) { Task { await requestNotificationAuthorization() } }
        // Every 30s, check which sources are due. Only due connections perform network work.
        timer = Task { [weak self] in
            await self?.refreshDue()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
                await self?.refreshDue()
            }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        })
    }

    func setCloudSyncEnabled(_ enabled: Bool) async { await cloudSyncBridge?.setEnabled(enabled) }
    func syncCloudNow() { cloudSyncBridge?.syncNow() }
    func useThisMacForCloud() { cloudSyncBridge?.useThisMac() }
    func removeCloudCopy(context: PrivateCloudRemovalContext) async throws {
        guard let cloudSyncBridge else { throw PulseError.storage("iCloud sync is unavailable.") }
        try await cloudSyncBridge.removeCloudCopy(context: context)
    }
    func setCloudSyncStatus(_ status: PrivateCloudSyncStatus) { cloudSyncStatus = status }
    func setCloudSummary(_ summary: WidgetSnapshot?) {
        let first = cloudSummary == nil
        cloudSummary = summary
        if first, connections.isEmpty, let raw = summary?.defaultRangeRawValue,
           let range = MetricTimeRange(rawValue: raw) { selectRange(range) }
    }
    func widgetSnapshot() -> WidgetSnapshot {
        if connections.isEmpty, var summary = cloudSummary {
            summary.defaultRangeRawValue = selectedRange.rawValue
            return summary
        }
        return WidgetSnapshotBuilder.make(connections: connections, snapshots: snapshots,
            visibility: metricVisibilities, defaultRange: selectedRange, errors: Set(errors.keys))
    }

    func snapshot(for id: UUID) -> ProjectSnapshot? {
        sourceSnapshot(for: id)?.applyingVisibility(metricVisibilities[id] ?? MetricVisibility())
    }

    func sourceSnapshot(for id: UUID) -> ProjectSnapshot? {
        rawSnapshot(for: id)?.forRange(selectedRange)
    }

    func rawSnapshot(for id: UUID) -> ProjectSnapshot? {
        isDemo ? DemoMetricRanges.snapshots().first(where: { $0.projectID == id }) : snapshots[id]
    }

    func metricIsVisible(_ metricID: UUID, projectID: UUID, placement: MetricPlacement) -> Bool {
        guard let display = snapshot(for: projectID) else { return false }
        return (placement == .headline ? display.metrics : display.details ?? []).contains { $0.id == metricID }
    }

    func canSetMetric(_ metricID: UUID, visible: Bool, projectID: UUID, placement: MetricPlacement) -> Bool {
        guard let display = snapshot(for: projectID) else { return false }
        let selected = placement == .headline ? display.metrics : display.details ?? []
        if !visible { return placement != .headline || selected.count > 1 }
        if placement == .drawer, display.metrics.contains(where: { $0.id == metricID }) { return false }
        return selected.count < (placement == .headline ? 3 : 6)
    }

    private func editableVisibility(projectID: UUID) throws -> MetricVisibility {
        guard isDemo || connections.contains(where: { $0.id == projectID }),
              snapshot(for: projectID) != nil else {
            throw PulseError.invalidConfiguration("This connection is no longer available.")
        }
        return metricVisibilities[projectID] ?? MetricVisibility()
    }

    func setMetricVisible(_ visible: Bool, metricID: UUID, projectID: UUID, placement: MetricPlacement) async throws {
        guard let source = sourceSnapshot(for: projectID), source.metricCatalog.contains(where: { $0.id == metricID }) else {
            throw PulseError.invalidConfiguration("This number is no longer available.")
        }
        guard canSetMetric(metricID, visible: visible, projectID: projectID, placement: placement) else { return }
        var next = try editableVisibility(projectID: projectID)
        let display = snapshot(for: projectID)!
        if placement == .headline {
            next.headlineMetricIDs = display.metrics.map(\.id)
            if next.detailMetricIDs == nil { next.detailMetricIDs = (display.details ?? []).map(\.id) }
        } else { next.detailMetricIDs = (display.details ?? []).map(\.id) }
        var selected = placement == .headline ? next.headlineMetricIDs ?? [] : next.detailMetricIDs ?? []
        selected.removeAll { $0 == metricID }
        if visible { selected.append(metricID); next.hiddenMetricIDs.remove(metricID) }
        if placement == .headline {
            next.headlineMetricIDs = selected
            if visible { next.detailMetricIDs?.removeAll { $0 == metricID } }
        } else { next.detailMetricIDs = selected }
        try await persistMetricVisibility(next, projectID: projectID)
    }

    func replaceHeadline(_ metricID: UUID, replacing oldID: UUID, projectID: UUID) async throws {
        guard let source = sourceSnapshot(for: projectID), source.metricCatalog.contains(where: { $0.id == metricID }) else {
            throw PulseError.invalidConfiguration("This number is no longer available.")
        }
        var next = try editableVisibility(projectID: projectID)
        let display = snapshot(for: projectID)!
        next.headlineMetricIDs = display.metrics.map(\.id)
        if next.detailMetricIDs == nil { next.detailMetricIDs = (display.details ?? []).map(\.id) }
        guard let index = next.headlineMetricIDs?.firstIndex(of: oldID),
              next.headlineMetricIDs?.contains(metricID) == false else { return }
        next.headlineMetricIDs?[index] = metricID
        next.detailMetricIDs?.removeAll { $0 == metricID }
        next.hiddenMetricIDs.remove(metricID)
        try await persistMetricVisibility(next, projectID: projectID)
    }

    func breakdownIsVisible(_ id: String, projectID: UUID) -> Bool {
        (snapshot(for: projectID)?.breakdowns ?? []).contains { $0.id == id }
    }

    func setBreakdownVisible(_ visible: Bool, breakdownID: String, projectID: UUID) async throws {
        guard let source = sourceSnapshot(for: projectID), (source.breakdowns ?? []).contains(where: { $0.id == breakdownID }) else {
            throw PulseError.invalidConfiguration("This breakdown is no longer available.")
        }
        var next = try editableVisibility(projectID: projectID)
        var selected = (snapshot(for: projectID)?.breakdowns ?? []).map(\.id)
        selected.removeAll { $0 == breakdownID }
        guard !visible || selected.count < 2 else { return }
        if visible { selected.append(breakdownID) }
        next.visibleBreakdownIDs = selected
        try await persistMetricVisibility(next, projectID: projectID)
    }

    func resetKPIs(projectID: UUID) async throws {
        guard isDemo || connections.contains(where: { $0.id == projectID }) else { return }
        try await persistMetricVisibility(MetricVisibility(), projectID: projectID)
    }

    private func persistMetricVisibility(_ next: MetricVisibility, projectID: UUID) async throws {
        // Update immediately so successive menu choices build on the last one.
        guard isDemo || storage != nil else { throw PulseError.storage("Local storage is unavailable.") }
        metricVisibilities[projectID] = next
        if isDemo { return }
        guard let storage else { return }
        let previous = visibilityWrites[projectID]?.task
        let writeID = UUID()
        let write = Task {
            _ = try? await previous?.value
            try await storage.saveMetricVisibility(next, projectID: projectID)
        }
        visibilityWrites[projectID] = (writeID, write)
        do {
            try await write.value
            if visibilityWrites[projectID]?.id == writeID { visibilityWrites.removeValue(forKey: projectID) }
        } catch {
            // Reload only if a newer selection or removal has not superseded it.
            if visibilityWrites[projectID]?.id == writeID {
                let persisted = try? await storage.metricVisibility(projectID: projectID)
                if visibilityWrites[projectID]?.id == writeID {
                    visibilityWrites.removeValue(forKey: projectID)
                    if connections.contains(where: { $0.id == projectID }) {
                        metricVisibilities[projectID] = persisted ?? MetricVisibility()
                    }
                }
            }
            throw error
        }
    }

    func selectRange(_ range: MetricTimeRange) {
        // An explicit choice wins even while a newly added source is loading.
        pendingRangeReveals.removeAll()
        setSelectedRange(range)
    }

    private func setSelectedRange(_ range: MetricTimeRange) {
        selectedRange = range
        guard let viewStateURL else { return }
        do {
            try JSONEncoder().encode(["range": range.rawValue]).write(to: viewStateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: viewStateURL.path)
        } catch { storageError = "The selected time range couldn’t be saved." }
    }

    func refreshDue() async {
        guard !isDemo else { return }
        let now = Date()
        let due = connections.filter { $0.enabled && now.timeIntervalSince(lastAttempts[$0.id] ?? .distantPast) >= Double(max(60, $0.intervalSeconds)) }
        await withTaskGroup(of: Void.self) { group in
            for connection in due { group.addTask { await self.refresh(connection) } }
        }
    }

    func refreshAll() async {
        guard !isDemo else { return }
        inspectedConnections.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for connection in connections where connection.enabled { group.addTask { await self.refresh(connection) } }
        }
    }

    func collect(_ connection: ProjectConnection, secret: String?) async throws -> ProjectSnapshot {
        switch connection.kind {
        case .http: return try await HTTPConnector().collect(connection: connection, secret: secret)
        case .postgres: return try await PostgresConnector().collect(connection: connection, secret: secret)
        case .supabase: return try await SupabaseConnector().collect(connection: connection, secret: secret)
        }
    }

    private func refresh(_ candidate: ProjectConnection) async {
        var connection = candidate
        guard connection.enabled, isCurrent(connection), !refreshing.contains(connection.id), let storage else { return }
        refreshing.insert(connection.id)
        lastAttempts[connection.id] = Date()
        defer { refreshing.remove(connection.id) }
        do {
            let credentialStore = credentials
            let projectID = connection.id
            // macOS may wait for the user's Keychain approval. Keep that
            // protected wait off the main actor so the panel stays responsive.
            let secret = try await Task.detached(priority: .utility) {
                try credentialStore.load(for: projectID)
            }.value
            guard isCurrent(connection) else { return }
            connection = await inspectAutomaticStats(connection, secret: secret)
            guard isCurrent(connection) else { return }
            let snapshot = try await collect(connection, secret: secret)
            // A removed or edited connection cannot be overwritten by a late response.
            guard isCurrent(connection) else { return }
            let authorized = await notificationAuthorization()
            guard isCurrent(connection) else { return }
            let pending = try await storage.acceptSnapshot(snapshot, notificationsEnabled: connection.notificationsEnabled && authorized, expectedConnection: connection)
            guard isCurrent(connection) else { return }
            snapshots[connection.id] = snapshot
            errors.removeValue(forKey: connection.id)
            // Setup should reveal the newly connected source, including an API
            // that supplies totals only. Routine polls never change the range.
            if let originalRange = pendingRangeReveals.removeValue(forKey: connection.id), selectedRange == originalRange,
               !snapshot.supports(selectedRange), let range = snapshot.supports(.lifetime) ? .lifetime : snapshot.availableRanges.first {
                setSelectedRange(range)
            }
            if pending.count > 3, let first = pending.first, let last = pending.last {
                guard isCurrent(connection), connection.notificationsEnabled else { return }
                let summary = PulseEvent(id: "batch:\(first.id):\(last.id)", title: "\(pending.count) new events. \(last.title)", occurredAt: last.occurredAt)
                do {
                    try await notify(summary, project: connection)
                    for event in pending { try await storage.markNotified(projectID: connection.id, eventID: event.id) }
                } catch { errors[connection.id] = "Updated. An alert is waiting to be delivered." }
            } else { for event in pending {
                guard isCurrent(connection), connection.notificationsEnabled else { break }
                do {
                    try await notify(event, project: connection)
                    try await storage.markNotified(projectID: connection.id, eventID: event.id)
                } catch {
                    // A failed delivery stays pending in SQLite for the next collection.
                    errors[connection.id] = "Updated. An alert is waiting to be delivered."
                }
            } }
            await loadEvents()
        } catch {
            guard isCurrent(connection) else { return }
            errors[connection.id] = error.localizedDescription
        }
    }

    private func isCurrent(_ connection: ProjectConnection) -> Bool {
        connections.contains { $0.hasSameCollectionConfiguration(as: connection) }
    }

    private func inspectionKey(_ connection: ProjectConnection) -> String { connection.id.uuidString + connection.credentialVersion.uuidString + connection.endpoint + connection.query }

    private func inspectAutomaticStats(_ connection: ProjectConnection, secret: String?) async -> ProjectConnection {
        let isSQL = connection.kind == .supabase && connection.endpoint.hasPrefix("https://api.supabase.com/v1/projects/")
        guard connection.kind == .postgres || connection.kind == .supabase else { return connection }
        guard inspectedConnections.insert(inspectionKey(connection)).inserted else { return connection }
        var completed = false
        defer {
            // Edits or a temporary failure during an await should allow the
            // current source to be inspected again on its next refresh.
            if !completed { inspectedConnections.remove(inspectionKey(connection)) }
        }
        do {
            if connection.kind == .supabase, !isSQL {
                let enriched = try SupabaseConnector.enrichCountPlan(connection)
                guard enriched != connection else { completed = true; return connection }
                guard !isMutating, let storage,
                      let index = connections.firstIndex(where: { $0.hasSameCollectionConfiguration(as: connection) }) else { return connection }
                isMutating = true
                defer { isMutating = false }
                var updated = connections
                updated[index] = enriched
                try await storage.saveConnections(updated)
                connections = updated
                completed = true
                return enriched
            }
            let connector = PostgresConnector()
            let available: [DatabaseTable]
            if isSQL { available = connection.sourceTables ?? [] }
            else { available = try await connector.discoverTables(connection: connection, secret: secret) }
            guard isCurrent(connection) else { return connection }
            var structuralCheck = connection
            structuralCheck.kind = .postgres
            if isSQL { structuralCheck.endpoint = "postgresql://reader@localhost/pulse" }
            let selected = PostgresConnector.inferredSourceTables(connection: structuralCheck, available: available)
            guard !selected.isEmpty else { completed = true; return connection }
            let relationships: [DatabaseRelationship]
            let columns: [DatabaseColumn]
            if isSQL {
                relationships = connection.autoStats?.relationships ?? []
                let data = try await SupabaseConnector().readOnlyRows(connection: connection, secret: secret,
                                                                    query: DatabaseAnalytics.columnDiscoveryQuery(tables: selected))
                let rows = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
                columns = rows.compactMap { row in
                    guard let text = row["pulse_column"] as? String, let data = text.data(using: .utf8) else { return nil }
                    return try? JSONDecoder().decode(DatabaseColumn.self, from: data)
                }
            } else {
                relationships = try await connector.discoverRelationships(connection: connection, secret: secret, tables: available)
                columns = (try? await connector.discoverColumns(connection: connection, secret: secret, tables: selected)) ?? []
            }
            try Task.checkCancellation()
            guard !isMutating, let storage,
                  let index = connections.firstIndex(where: { $0.hasSameCollectionConfiguration(as: connection) }) else { return connection }
            let current = connections[index]
            let upgraded = PostgresConnector.configureAnalytics(base: current, tables: selected, relationships: relationships, columns: columns)
            guard upgraded != current else { completed = true; return current }
            isMutating = true
            defer { isMutating = false }
            var updated = connections
            updated[index] = upgraded
            try await storage.saveConnections(updated)
            connections = updated
            completed = true
            return upgraded
        } catch { return connection }
    }

    func save(_ candidate: ProjectConnection, secret: String) async throws {
        guard !isMutating else { throw PulseError.storage("Another connection is being updated. Try again in a moment.") }
        isMutating = true
        defer { isMutating = false }
        var connection = candidate
        let isNewConnection = !connections.contains { $0.id == connection.id }
        guard let storage else { throw PulseError.storage("Local storage is unavailable.") }
        try ConnectorValidation.validate(connection)
        let previous = try credentials.load(for: connection.id)
        if (previous ?? "") != secret { connection.credentialVersion = UUID() }
        var needsInspection = false
        if let old = connections.first(where: { $0.id == connection.id }),
           old.endpoint != connection.endpoint || old.query != connection.query || old.credentialVersion != connection.credentialVersion {
            connection.autoStats = nil
            needsInspection = true
            if old.endpoint != connection.endpoint || old.query != connection.query { connection.sourceTables = nil }
        }
        if secret.isEmpty { try credentials.delete(for: connection.id) }
        else { try credentials.save(secret: secret, for: connection.id) }
        var updated = connections
        if let index = updated.firstIndex(where: { $0.id == connection.id }) { updated[index] = connection }
        else { updated.append(connection) }
        do { try await storage.saveConnections(updated) }
        catch {
            if let previous { try? credentials.save(secret: previous, for: connection.id) }
            else { try? credentials.delete(for: connection.id) }
            throw error
        }
        if isNewConnection { pendingRangeReveals[connection.id] = selectedRange }
        connections = updated
        if needsInspection { inspectedConnections.remove(inspectionKey(connection)) }
        else if connection.sourceTables != nil { inspectedConnections.insert(inspectionKey(connection)) }
        // Storage resets caches and event baselines when the source or credential changes.
        snapshots = Dictionary(uniqueKeysWithValues: try await storage.loadSnapshots().map { ($0.projectID, $0) })
        await loadEvents()
        showExamples = false
        if connection.notificationsEnabled { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        lastAttempts.removeValue(forKey: connection.id)
        Task { await refresh(connection) }
    }

    func secret(for id: UUID) throws -> String { try credentials.load(for: id) ?? "" }

    func updateIcon(projectID: UUID, symbol: String, imageData: Data?) async throws {
        if isDemo, let index = demoProjects.firstIndex(where: { $0.id == projectID }) {
            try ProjectIconLimits.validate(symbol: symbol, imageData: imageData)
            demoProjects[index].symbol = symbol
            demoProjects[index].iconImageData = imageData
            return
        }
        guard !isMutating else { throw PulseError.storage("Another connection is being updated. Try again in a moment.") }
        guard let storage, let index = connections.firstIndex(where: { $0.id == projectID }) else {
            throw PulseError.storage("This connection is no longer available.")
        }
        isMutating = true
        defer { isMutating = false }
        // Icon edits are local presentation changes. They never load a
        // credential, reset a baseline or make a source request.
        let updated = try await storage.updateIcon(projectID: projectID, symbol: symbol, imageData: imageData)
        connections[index] = updated
    }

    func remove(_ connection: ProjectConnection) async throws {
        guard !isMutating else { throw PulseError.storage("Another connection is being updated. Try again in a moment.") }
        isMutating = true
        defer { isMutating = false }
        guard let storage else { throw PulseError.storage("Local storage is unavailable.") }
        let previous = try credentials.load(for: connection.id)
        try credentials.delete(for: connection.id)
        do { try await storage.removeProject(connection.id) }
        catch { if let previous { try? credentials.save(secret: previous, for: connection.id) }; throw error }
        pendingRangeReveals.removeValue(forKey: connection.id)
        connections.removeAll { $0.id == connection.id }
        snapshots.removeValue(forKey: connection.id)
        errors.removeValue(forKey: connection.id)
        recentEvents.removeValue(forKey: connection.id)
        metricVisibilities.removeValue(forKey: connection.id)
        visibilityWrites.removeValue(forKey: connection.id)
    }

    func loadEvents() async {
        guard let storage else { return }
        for connection in connections { recentEvents[connection.id] = (try? await storage.eventsForDisplay(projectID: connection.id, limit: 3)) ?? [] }
    }

    private func notificationAuthorization() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    private func requestNotificationAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func testNotification(for project: ProjectConnection) async throws {
        await requestNotificationAuthorization()
        guard await notificationAuthorization() else {
            throw PulseError.response("Allow notifications for Pulse in System Settings to receive alerts.")
        }
        try await notify(PulseEvent(id: "test:\(UUID().uuidString)", title: "This is a test notification from Pulse.", occurredAt: Date()), project: project)
    }

    private func notify(_ event: PulseEvent, project: ProjectConnection) async throws {
        let content = UNMutableNotificationContent()
        content.title = project.name
        content.body = event.title
        content.threadIdentifier = project.id.uuidString
        content.sound = .default
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(project.id).\(event.id)", content: content, trigger: nil))
    }
}
