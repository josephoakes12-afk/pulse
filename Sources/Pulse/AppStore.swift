import AppKit
import Combine
import Foundation
import PulseCore
import UserNotifications

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()
    @Published private(set) var connections: [ProjectConnection] = []
    @Published private(set) var snapshots: [UUID: ProjectSnapshot] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var refreshing: Set<UUID> = []
    @Published private(set) var recentEvents: [UUID: [PulseEvent]] = [:]
    @Published var storageError: String?
    @Published var showExamples: Bool = true
    private var storage: LocalStore?
    private let credentials = CredentialStore()
    private var timer: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var lastAttempts: [UUID: Date] = [:]
    private var started = false
    private var isMutating = false
    private var inspectedConnections: Set<String> = []

    var isDemo: Bool { connections.isEmpty && showExamples }
    var displayedConnections: [ProjectConnection] { isDemo ? DemoData.projects : connections }
    var isRefreshing: Bool { !refreshing.isEmpty }

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
        } catch { storageError = "Pulse couldn’t open its local storage. \(error.localizedDescription)" }
    }

    func start() async {
        guard !started, let storage else { return }
        started = true
        do {
            connections = try await storage.loadConnections()
            snapshots = Dictionary(uniqueKeysWithValues: try await storage.loadSnapshots().map { ($0.projectID, $0) })
            await loadEvents()
        } catch { storageError = error.localizedDescription }
        if ProcessInfo.processInfo.arguments.contains("--empty") { showExamples = false }
        if ProcessInfo.processInfo.arguments.contains("--demo") { connections = []; snapshots = [:]; showExamples = true }
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

    func snapshot(for id: UUID) -> ProjectSnapshot? {
        isDemo ? DemoData.snapshots().first(where: { $0.projectID == id }) : snapshots[id]
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
        await withTaskGroup(of: Void.self) { group in
            for connection in connections where connection.enabled { group.addTask { await self.refresh(connection) } }
        }
    }

    func collect(_ connection: ProjectConnection, secret: String?) async throws -> ProjectSnapshot {
        switch connection.kind {
        case .http: return try await HTTPConnector().collect(connection: connection, secret: secret)
        case .postgres: return try await PostgresConnector().collect(connection: connection, secret: secret)
        }
    }

    private func refresh(_ candidate: ProjectConnection) async {
        var connection = candidate
        guard connection.enabled, connections.contains(connection), !refreshing.contains(connection.id), let storage else { return }
        refreshing.insert(connection.id)
        lastAttempts[connection.id] = Date()
        defer { refreshing.remove(connection.id) }
        do {
            let secret = try credentials.load(for: connection.id)
            connection = await inspectAutomaticStats(connection, secret: secret)
            guard connections.contains(connection) else { return }
            let snapshot = try await collect(connection, secret: secret)
            // A removed or edited connection cannot be overwritten by a late response.
            guard connections.contains(connection) else { return }
            let authorized = await notificationAuthorization()
            guard connections.contains(connection) else { return }
            let pending = try await storage.acceptSnapshot(snapshot, notificationsEnabled: connection.notificationsEnabled && authorized, expectedConnection: connection)
            guard connections.contains(connection) else { return }
            snapshots[connection.id] = snapshot
            errors.removeValue(forKey: connection.id)
            if pending.count > 3, let first = pending.first, let last = pending.last {
                guard connections.contains(connection), connection.notificationsEnabled else { return }
                let summary = PulseEvent(id: "batch:\(first.id):\(last.id)", title: "\(pending.count) new events. \(last.title)", occurredAt: last.occurredAt)
                do {
                    try await notify(summary, project: connection)
                    for event in pending { try await storage.markNotified(projectID: connection.id, eventID: event.id) }
                } catch { errors[connection.id] = "Updated. An alert is waiting to be delivered." }
            } else { for event in pending {
                guard connections.contains(connection), connection.notificationsEnabled else { break }
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
            guard connections.contains(connection) else { return }
            errors[connection.id] = error.localizedDescription
        }
    }

    private func inspectionKey(_ connection: ProjectConnection) -> String { connection.id.uuidString + connection.credentialVersion.uuidString + connection.endpoint + connection.query }

    private func inspectAutomaticStats(_ connection: ProjectConnection, secret: String?) async -> ProjectConnection {
        guard connection.kind == .postgres, connection.autoStats == nil,
              inspectedConnections.insert(inspectionKey(connection)).inserted else { return connection }
        var completed = false
        defer {
            // Edits or a temporary failure during an await should allow the
            // current source to be inspected again on its next refresh.
            if !completed { inspectedConnections.remove(inspectionKey(connection)) }
        }
        do {
            let connector = PostgresConnector()
            let available = try await connector.discoverTables(connection: connection, secret: secret)
            guard connections.contains(connection) else { return connection }
            let selected = PostgresConnector.inferredSourceTables(connection: connection, available: available)
            guard !selected.isEmpty else { completed = true; return connection }
            let relationships = try await connector.discoverRelationships(connection: connection, secret: secret, tables: available)
            guard !isMutating, connections.contains(connection), let storage,
                  let index = connections.firstIndex(of: connection) else { return connection }
            let upgraded = PostgresConnector.configureAnalytics(base: connection, tables: selected, relationships: relationships)
            guard upgraded != connection else { completed = true; return connection }
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

    func remove(_ connection: ProjectConnection) async throws {
        guard !isMutating else { throw PulseError.storage("Another connection is being updated. Try again in a moment.") }
        isMutating = true
        defer { isMutating = false }
        guard let storage else { throw PulseError.storage("Local storage is unavailable.") }
        let previous = try credentials.load(for: connection.id)
        try credentials.delete(for: connection.id)
        do { try await storage.removeProject(connection.id) }
        catch { if let previous { try? credentials.save(secret: previous, for: connection.id) }; throw error }
        connections.removeAll { $0.id == connection.id }
        snapshots.removeValue(forKey: connection.id)
        errors.removeValue(forKey: connection.id)
        recentEvents.removeValue(forKey: connection.id)
    }

    func loadEvents() async {
        guard let storage else { return }
        for connection in connections { recentEvents[connection.id] = (try? await storage.eventsForDisplay(projectID: connection.id, limit: 3)) ?? [] }
    }

    private func notificationAuthorization() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
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
