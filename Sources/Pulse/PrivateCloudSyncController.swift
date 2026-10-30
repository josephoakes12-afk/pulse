import AppKit
@preconcurrency import CloudKit
import Combine
import Foundation
import PulseCore
import PulseWidgetData

/// The Settings confirmation holds this immutable value. Its opaque account
/// binding is never displayed or included in the synced payload.
struct PrivateCloudRemovalContext: Equatable, Sendable {
    fileprivate let accountID: String
    fileprivate let publisherID: UUID
}

struct PrivateCloudSyncStatus {
    var enabled = false
    var configured = false
    var title = "Off"
    var verifiedAt: Date?
    var needsAccountApproval = false
    var otherPublisherID: UUID?
    var working = false
    var copyRemoved = false
    var removalContext: PrivateCloudRemovalContext?
    var canRemoveCopy: Bool { configured && !working && !needsAccountApproval && removalContext != nil }
}

/// A small display-only bridge. Local connections and their credentials never
/// enter the transport; receiving a summary never creates a connection.
@MainActor
final class PrivateCloudSyncController {
    private struct Preferences: Codable {
        var version = 1
        var publisherID = UUID()
        var enabled = false
        var accountID: String?
        var hasPublished = false
        var removedPublisherID: UUID?
    }
    private struct SavedSummary: Codable {
        var accountID: String
        var payload: CloudSyncSnapshot
        var verifiedAt: Date
    }

    private weak var app: AppStore?
    private let transport: PrivateCloudTransport?
    private let preferencesURL: URL
    private let summaryURL: URL
    private let outboundURL: URL
    private var preferences: Preferences
    private var preferencesReadable = true
    private var changes: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var timer: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var removalWork: Task<PrivateCloudReceipt, Error>?
    private var removingCopy = false
    private var delayedWork: Task<Void, Never>?
    private var pendingChange = false
    private var generation = UUID()
    private var lastLocal: CloudSyncSnapshot?
    private var nextAttempt = Date.distantPast
    private var serverRetryUntil = Date.distantPast
    private var status = PrivateCloudSyncStatus()

    init(app: AppStore, directory: URL) {
        self.app = app
        let arguments = ProcessInfo.processInfo.arguments
        // Test/preview/demo profiles must never touch someone's cloud data.
        transport = arguments.contains("--demo") || arguments.contains("--data-directory") ? nil : PrivateCloudTransport()
        preferencesURL = directory.appendingPathComponent("icloud-sync.json")
        summaryURL = directory.appendingPathComponent("icloud-summary.json")
        outboundURL = directory.appendingPathComponent("icloud-outbound.json")
        do {
            if FileManager.default.fileExists(atPath: preferencesURL.path) {
                let value = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: preferencesURL))
                guard value.version == 1 else { throw CloudSyncSnapshotError.unsupportedVersion }
                preferences = value
            } else { preferences = Preferences() }
        } catch {
            preferences = Preferences()
            preferencesReadable = false
        }
        status.enabled = preferences.enabled
        status.configured = transport != nil && preferencesReadable
        status.title = !preferencesReadable ? "Couldn’t read iCloud settings" : transport == nil ? "Unavailable in this build" : preferences.enabled ? "Connecting…" : "Off"
        status.copyRemoved = preferences.removedPublisherID != nil
        if let removed = preferences.removedPublisherID {
            status.otherPublisherID = removed
            if transport != nil { status.title = "Cloud copy removed" }
        } else if let accountID = preferences.accountID,
                  let data = try? Data(contentsOf: summaryURL), data.count <= CloudSyncSnapshot.maximumEncodedBytes + 2_048,
                  let saved = try? JSONDecoder().decode(SavedSummary.self, from: data), saved.accountID == accountID,
                  !saved.payload.isCleared, (try? saved.payload.validate()) != nil {
            status.removalContext = PrivateCloudRemovalContext(accountID: accountID, publisherID: saved.payload.publisherID)
        }
        updateStatus()

        let publishers: [AnyPublisher<Void, Never>] = [
            app.$connections.map { _ in () }.eraseToAnyPublisher(),
            app.$snapshots.map { _ in () }.eraseToAnyPublisher(),
            app.$metricVisibilities.map { _ in () }.eraseToAnyPublisher(),
            app.$selectedRange.map { _ in () }.eraseToAnyPublisher(),
            app.$errors.map { _ in () }.eraseToAnyPublisher()
        ]
        changes = Publishers.MergeMany(publishers)
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.schedule() }
        observers.append(NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.accountChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.schedule() }
        })
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(120)) } catch { break }
                self?.schedule()
            }
        }
        schedule()
    }

    func setEnabled(_ enabled: Bool, replacingPublisherID: UUID? = nil) async {
        guard preferencesReadable, !removingCopy, let transport else { return }
        let previousPreferences = preferences
        cancelWork()
        if !enabled {
            preferences.enabled = false
            status.enabled = false
            status.title = status.copyRemoved ? "Cloud copy removed" : "Off"
            status.needsAccountApproval = false
            status.otherPublisherID = preferences.removedPublisherID
            app?.setCloudSummary(nil)
            do { try savePreferences() } catch { status.title = "Couldn’t save iCloud settings" }
            updateStatus()
            return
        }
        let token = generation
        status.enabled = true
        status.working = true; status.title = "Connecting…"; updateStatus()
        do {
            let account = try await transport.account()
            guard token == generation else { return }
            guard case .available(let accountID) = account else {
                showAccountState(account); return
            }
            // An explicit enable/reconnect is the only way to bind an account.
            if preferences.accountID != accountID {
                preferences.hasPublished = false
                preferences.removedPublisherID = nil
                status.copyRemoved = false
                status.removalContext = nil
                serverRetryUntil = .distantPast
                lastLocal = nil
                app?.setCloudSummary(nil)
                try? FileManager.default.removeItem(at: summaryURL)
                try? FileManager.default.removeItem(at: outboundURL)
            }
            preferences.accountID = accountID
            preferences.enabled = true
            try savePreferences()
            status.enabled = true
            status.needsAccountApproval = false
            status.working = false
            nextAttempt = .distantPast
            updateStatus()
            schedule(force: true, replacingPublisherID: replacingPublisherID)
        } catch {
            guard token == generation else { return }
            preferences = previousPreferences
            status.enabled = previousPreferences.enabled
            status.working = false; status.title = "Couldn’t connect to iCloud"; updateStatus()
        }
    }

    func syncNow() { schedule(force: true) }

    func useThisMac() {
        guard let owner = status.otherPublisherID, app?.connections.isEmpty == false else { return }
        if status.copyRemoved {
            Task { await setEnabled(true, replacingPublisherID: owner) }
            return
        }
        schedule(force: true, replacingPublisherID: owner)
    }

    /// The caller must first confirm the exact context shown by Settings. Sync
    /// is persisted Off before any clearing request, and only display caches
    /// are removed locally; source connections and credentials are untouched.
    func removeCloudCopy(context: PrivateCloudRemovalContext) async throws {
        guard preferencesReadable, status.configured, !removingCopy,
              preferences.accountID == context.accountID, status.removalContext == context,
              let transport else { throw PrivateCloudTransportError.accountChanged }
        cancelWork()
        let token = generation
        preferences.enabled = false
        status.enabled = false
        app?.setCloudSummary(nil)
        // If Off cannot be persisted, don't make a remote change which could
        // be undone automatically on the next launch.
        do {
            try savePreferences()
            try removeDisplayCaches()
        } catch {
            status.title = "Couldn’t save iCloud settings"
            updateStatus()
            throw error
        }
        lastLocal = nil
        guard Date() >= serverRetryUntil else {
            status.title = "Cloud removal waiting for iCloud"
            updateStatus()
            throw PrivateCloudTransportError.unavailable(retryAfter: serverRetryUntil.timeIntervalSinceNow)
        }
        removingCopy = true
        status.working = true
        status.title = "Removing cloud copy…"
        updateStatus()
        let task = Task {
            try await transport.removeCopy(expectedAccountID: context.accountID, confirmedPublisherID: context.publisherID)
        }
        removalWork = task
        defer {
            if token == generation {
                removalWork = nil
                removingCopy = false
                status.working = false
                updateStatus()
            }
        }
        do {
            let receipt = try await withTaskCancellationHandler { try await task.value }
                onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard token == generation, preferences.accountID == receipt.accountID else {
                throw PrivateCloudTransportError.accountChanged
            }
            acceptRemoved(receipt, requestedHere: true)
        } catch {
            guard token == generation else { throw error }
            if case PrivateCloudTransportError.unavailable(let delay) = error {
                serverRetryUntil = Date().addingTimeInterval(max(120, delay ?? 120))
                nextAttempt = serverRetryUntil
            }
            status.title = "Couldn’t remove cloud copy"
            updateStatus()
            throw error
        }
    }

    private func accountChanged() {
        cancelWork()
        // Hide another account's cached summary immediately, before network I/O.
        app?.setCloudSummary(nil)
        try? FileManager.default.removeItem(at: summaryURL)
        status.verifiedAt = nil
        status.otherPublisherID = nil
        status.removalContext = nil
        status.copyRemoved = false
        if preferences.enabled {
            status.title = "Apple Account changed"
            status.needsAccountApproval = true
        } else { status.title = "Off" }
        updateStatus()
    }

    private func schedule(force: Bool = false, replacingPublisherID: UUID? = nil) {
        guard preferences.enabled, status.configured, !status.needsAccountApproval, !removingCopy else { return }
        guard work == nil else { pendingChange = true; return }
        let allowedAt = force ? serverRetryUntil : max(nextAttempt, serverRetryUntil)
        if allowedAt > Date() {
            pendingChange = true
            if replacingPublisherID != nil { delayedWork?.cancel(); delayedWork = nil }
            if delayedWork == nil {
                let token = generation
                delayedWork = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(0, allowedAt.timeIntervalSinceNow))) } catch { return }
                    guard let self, token == self.generation else { return }
                    self.delayedWork = nil
                    self.pendingChange = false
                    self.schedule(force: force, replacingPublisherID: replacingPublisherID)
                }
            }
            return
        }
        delayedWork?.cancel(); delayedWork = nil
        pendingChange = false
        let token = generation
        work = Task { [weak self] in
            guard let self else { return }
            await self.synchronize(token: token, replacingPublisherID: replacingPublisherID)
            if token == self.generation {
                self.work = nil
                if self.pendingChange { self.schedule() }
            }
        }
    }

    private func synchronize(token: UUID, replacingPublisherID: UUID?) async {
        guard let transport, let app else { return }
        status.working = true; status.title = "Syncing…"; updateStatus()
        nextAttempt = Date().addingTimeInterval(30)
        defer {
            if token == generation { status.working = false; updateStatus() }
        }
        do {
            let account = try await transport.account()
            guard token == generation, !Task.isCancelled else { return }
            guard case .available(let accountID) = account else { showAccountState(account); return }
            guard preferences.accountID == accountID else {
                accountChanged(); return
            }
            loadCachedSummary(accountID: accountID)
            if lastLocal == nil, let data = try? Data(contentsOf: outboundURL),
               data.count <= CloudSyncSnapshot.maximumEncodedBytes + 2_048,
               let saved = try? JSONDecoder().decode(SavedSummary.self, from: data), saved.accountID == accountID,
               saved.payload.publisherID == preferences.publisherID, (try? saved.payload.validate()) != nil {
                lastLocal = saved.payload
            }
            let remote = try await transport.fetch(expectedAccountID: accountID)
            try Task.checkCancellation()
            guard token == generation else { return }
            if lastLocal == nil, remote?.payload.publisherID == preferences.publisherID {
                lastLocal = remote?.payload
            }

            // A fresh receiving Mac has no outbound candidate. A Mac that has
            // already published must send an empty snapshot after removals.
            let hasExplicitResume = preferences.removedPublisherID == nil || replacingPublisherID == preferences.removedPublisherID
            let canPublish = hasExplicitResume && (!app.connections.isEmpty || preferences.hasPublished)
            let candidate: CloudSyncSnapshot?
            if canPublish {
                var snapshot = WidgetSnapshotBuilder.make(connections: app.connections, snapshots: app.snapshots,
                    visibility: app.metricVisibilities, defaultRange: app.selectedRange, errors: Set(app.errors.keys))
                var next = try CloudSyncSnapshot.prepared(publisherID: preferences.publisherID, snapshot: snapshot)
                if let previous = lastLocal {
                    snapshot.generatedAt = previous.snapshot.generatedAt
                    let comparable = try CloudSyncSnapshot.prepared(publisherID: preferences.publisherID, snapshot: snapshot)
                    if comparable == previous { next = previous }
                }
                lastLocal = next
                try save(JSONEncoder().encode(SavedSummary(accountID: accountID, payload: next, verifiedAt: Date())), to: outboundURL)
                candidate = next
            } else { candidate = nil }

            let action = try CloudSyncPolicy.decision(enabled: preferences.enabled, boundAccountID: preferences.accountID,
                actualAccountID: accountID, local: candidate, remote: remote?.payload,
                publisherID: preferences.publisherID, replacingPublisherID: replacingPublisherID)
            switch action {
            case .off: return
            case .pausedAccountChange: accountChanged()
            case .publish(let payload, let replacing):
                let receipt = try await transport.publish(payload, expectedAccountID: accountID, replacingPublisherID: replacing)
                try Task.checkCancellation()
                guard token == generation else { return }
                preferences.hasPublished = true
                try savePreferences()
                accept(receipt)
            case .receive:
                if let remote { accept(remote) }
            case .unchanged:
                if let remote { accept(remote) }
                else {
                    app.setCloudSummary(nil)
                    status.title = status.copyRemoved ? "Cloud copy removed" : "Waiting for a Mac"
                    status.otherPublisherID = preferences.removedPublisherID
                }
            }
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            switch error {
            case PrivateCloudTransportError.accountChanged: accountChanged()
            case PrivateCloudTransportError.accountUnavailable: status.title = "Sign in to iCloud"
            case PrivateCloudTransportError.anotherPublisher(let id):
                status.otherPublisherID = id; status.title = "Another Mac is syncing"
            case PrivateCloudTransportError.quotaExceeded: status.title = "iCloud storage is full"
            case PrivateCloudTransportError.unavailable(let retry):
                serverRetryUntil = Date().addingTimeInterval(max(120, retry ?? 120))
                nextAttempt = serverRetryUntil
                status.title = "iCloud unavailable · retrying"
            case CloudSyncSnapshotError.snapshotTooLarge: status.title = "Summary is too large to sync"
            default: status.title = "Couldn’t sync · retrying"
            }
        }
    }

    private func accept(_ receipt: PrivateCloudReceipt) {
        guard receipt.accountID == preferences.accountID else { return }
        if receipt.payload.isCleared {
            acceptRemoved(receipt, requestedHere: false)
            return
        }
        let wasRemoved = preferences.removedPublisherID != nil
        preferences.removedPublisherID = nil
        status.copyRemoved = false
        status.removalContext = PrivateCloudRemovalContext(accountID: receipt.accountID, publisherID: receipt.payload.publisherID)
        status.verifiedAt = receipt.verifiedAt
        status.otherPublisherID = receipt.payload.publisherID == preferences.publisherID ? nil : receipt.payload.publisherID
        status.title = status.otherPublisherID == nil ? "Synced" : "Using another Mac"
        app?.setCloudSummary(status.otherPublisherID == nil ? nil : receipt.payload.snapshot)
        do {
            let value = SavedSummary(accountID: receipt.accountID, payload: receipt.payload, verifiedAt: receipt.verifiedAt)
            try save(JSONEncoder().encode(value), to: summaryURL)
            if wasRemoved { try savePreferences() }
        } catch { status.title = "Synced · couldn’t save local copy" }
    }

    private func acceptRemoved(_ receipt: PrivateCloudReceipt, requestedHere: Bool) {
        guard receipt.accountID == preferences.accountID, receipt.payload.isCleared else { return }
        cancelWork()
        preferences.enabled = false
        preferences.hasPublished = false
        preferences.removedPublisherID = receipt.payload.publisherID
        lastLocal = nil
        status.enabled = false
        status.copyRemoved = true
        status.removalContext = nil
        status.otherPublisherID = receipt.payload.publisherID
        status.verifiedAt = receipt.verifiedAt
        status.title = requestedHere ? "Cloud copy removed" : "Removed on another Mac"
        app?.setCloudSummary(nil)
        do {
            try savePreferences()
            try removeDisplayCaches()
        } catch { status.title = "Cloud copy removed · couldn’t save local state" }
        updateStatus()
    }

    private func loadCachedSummary(accountID: String) {
        guard app?.cloudSummary == nil,
              let data = try? Data(contentsOf: summaryURL), data.count <= CloudSyncSnapshot.maximumEncodedBytes + 2_048,
              let saved = try? JSONDecoder().decode(SavedSummary.self, from: data), saved.accountID == accountID,
              !saved.payload.isCleared,
              saved.payload.publisherID != preferences.publisherID,
              (try? saved.payload.validate()) != nil else { return }
        app?.setCloudSummary(saved.payload.snapshot)
        status.verifiedAt = saved.verifiedAt
    }

    private func showAccountState(_ account: PrivateCloudAccountState) {
        status.working = false
        status.enabled = preferences.enabled
        switch account {
        case .available: break
        case .signedOut: status.title = "Sign in to iCloud"; app?.setCloudSummary(nil)
        case .restricted: status.title = "iCloud is restricted"; app?.setCloudSummary(nil)
        case .temporarilyUnavailable: status.title = "iCloud unavailable · retrying"
        }
        updateStatus()
    }

    private func cancelWork() {
        generation = UUID()
        work?.cancel(); work = nil
        removalWork?.cancel(); removalWork = nil
        removingCopy = false
        delayedWork?.cancel(); delayedWork = nil
        pendingChange = false
        status.working = false
    }

    private func savePreferences() throws { try save(JSONEncoder().encode(preferences), to: preferencesURL) }
    private func removeDisplayCaches() throws {
        for url in [summaryURL, outboundURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
    private func save(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func updateStatus() { app?.setCloudSyncStatus(status) }
}
