@preconcurrency import CloudKit
import CryptoKit
import Foundation
import PulseWidgetData
import Security

enum PrivateCloudAccountState: Equatable, Sendable {
    case available(accountID: String)
    case signedOut
    case restricted
    case temporarilyUnavailable
}

struct PrivateCloudReceipt: Sendable {
    let accountID: String
    let payload: CloudSyncSnapshot
    let verifiedAt: Date
    let modifiedAt: Date?
}

enum PrivateCloudTransportError: LocalizedError, Equatable, Sendable {
    case accountUnavailable
    case accountChanged
    case anotherPublisher(UUID)
    case conflict
    case invalidPayload
    case quotaExceeded
    case unavailable(retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .accountUnavailable: "Sign in to iCloud to sync Pulse."
        case .accountChanged: "Your iCloud account changed. Turn sync on again to use this account."
        case .anotherPublisher: "Another Mac is providing the iCloud summary."
        case .conflict: "The iCloud summary changed. Pulse will try again."
        case .invalidPayload: "Pulse couldn’t read the iCloud summary."
        case .quotaExceeded: "Your iCloud storage is full."
        case .unavailable: "iCloud is temporarily unavailable."
        }
    }
}

/// One small record in the person's private database. This transport never
/// opens the public/shared databases and never receives source credentials.
actor PrivateCloudTransport {
    static let recordType = "PulseSummaryV1"
    static let recordName = "current"
    static let payloadField = "payload"

    private let container: CKContainer
    private let database: CKDatabase
    private let containerIdentifier: String
    private let recordID = CKRecord.ID(recordName: PrivateCloudTransport.recordName)
    // Numeric diagnostics are safe to inspect without recording an Apple
    // error's userInfo dictionary, which may contain the affected record.
    private(set) var lastCloudErrorCode: Int?

    /// CloudKit can raise an Objective-C exception without its entitlement.
    /// Source builds and unsigned previews therefore stay local before any
    /// CloudKit container is constructed.
    init?(bundle: Bundle = .main) {
        guard let identifier = bundle.object(forInfoDictionaryKey: "PulseCloudContainerIdentifier") as? String,
              identifier.hasPrefix("iCloud."), identifier.utf8.count <= 255,
              identifier.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }),
              let task = SecTaskCreateFromSelf(nil),
              let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String],
              services.contains("CloudKit"),
              let identifiers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
              identifiers.contains(identifier),
              let environment = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-environment" as CFString, nil) as? String,
              ["Development", "Production"].contains(environment) else { return nil }
        containerIdentifier = identifier
        container = CKContainer(identifier: identifier)
        database = container.privateCloudDatabase
    }

    func account() async throws -> PrivateCloudAccountState {
        do { return try await readAccount() }
        catch {
            if (error as? CKError)?.code == .notAuthenticated { return .signedOut }
            throw sanitized(error)
        }
    }

    private func readAccount() async throws -> PrivateCloudAccountState {
        let cloud = container
        let status: CKAccountStatus = try await boundedRequest { request in
            cloud.accountStatus { status, error in
                if let error { request.finish(.failure(error)) }
                else { request.finish(.success(status)) }
            }
        }
        switch status {
        case .available:
            let name: String = try await boundedRequest { request in
                cloud.fetchUserRecordID { id, error in
                    if let error { request.finish(.failure(error)) }
                    else if let id { request.finish(.success(id.recordName)) }
                    else { request.finish(.failure(PrivateCloudTransportError.accountUnavailable)) }
                }
            }
            // The opaque account token stays local and can't be correlated with
            // another application's CloudKit user identifier.
            let digest = SHA256.hash(data: Data("\(containerIdentifier)\u{0}\(name)".utf8))
            return .available(accountID: digest.map { String(format: "%02x", $0) }.joined())
        case .noAccount: return .signedOut
        case .restricted: return .restricted
        case .couldNotDetermine, .temporarilyUnavailable: return .temporarilyUnavailable
        @unknown default: return .temporarilyUnavailable
        }
    }

    func fetch(expectedAccountID: String) async throws -> PrivateCloudReceipt? {
        do {
            try await requireAccount(expectedAccountID)
            guard let record = try await fetchRecord() else { return nil }
            let payload = try decodedPayload(record)
            try await requireAccount(expectedAccountID)
            return receipt(record, payload: payload, accountID: expectedAccountID)
        } catch { throw sanitized(error) }
    }

    /// Same-publisher older summaries never overwrite newer numbers. Replacing
    /// a collecting Mac needs its exact current publisher ID, supplied only by
    /// the explicit replacement action in Settings.
    func publish(_ payload: CloudSyncSnapshot, expectedAccountID: String,
                 replacingPublisherID: UUID? = nil) async throws -> PrivateCloudReceipt {
        do {
            let data = try payload.encoded()
            try await requireAccount(expectedAccountID)
            for attempt in 0...2 {
                try Task.checkCancellation()
                let currentRecord = try await fetchRecord()
                if let currentRecord {
                    let current = try decodedPayload(currentRecord)
                    if current.publisherID != payload.publisherID {
                        guard replacingPublisherID == current.publisherID else {
                            throw PrivateCloudTransportError.anotherPublisher(current.publisherID)
                        }
                    } else if current.snapshot.generatedAt >= payload.snapshot.generatedAt {
                        guard current.snapshot.generatedAt > payload.snapshot.generatedAt || current == payload else {
                            throw PrivateCloudTransportError.conflict
                        }
                        try await requireAccount(expectedAccountID)
                        return receipt(currentRecord, payload: current, accountID: expectedAccountID)
                    }
                }
                let record = currentRecord ?? CKRecord(recordType: Self.recordType, recordID: recordID)
                record[Self.payloadField] = data as NSData
                // Bind the write to the account that enabled this sync session.
                try await requireAccount(expectedAccountID)
                do { try await saveRecord(record) }
                catch {
                    if Self.isConflict(error), attempt < 2 { continue }
                    throw error
                }
                // A successful CK operation is followed by a fresh server read;
                // the status shown by Pulse never relies on a local cache write.
                guard let verified = try await fetchRecord() else { throw PrivateCloudTransportError.invalidPayload }
                let verifiedPayload = try decodedPayload(verified)
                guard verifiedPayload.publisherID == payload.publisherID else {
                    throw PrivateCloudTransportError.anotherPublisher(verifiedPayload.publisherID)
                }
                guard verifiedPayload == payload || verifiedPayload.snapshot.generatedAt > payload.snapshot.generatedAt else {
                    throw PrivateCloudTransportError.conflict
                }
                try await requireAccount(expectedAccountID)
                return receipt(verified, payload: verifiedPayload, accountID: expectedAccountID)
            }
            throw PrivateCloudTransportError.conflict
        } catch { throw sanitized(error) }
    }

    private func requireAccount(_ expected: String) async throws {
        try Task.checkCancellation()
        guard case .available(let actual) = try await account() else {
            throw PrivateCloudTransportError.accountUnavailable
        }
        guard actual == expected else { throw PrivateCloudTransportError.accountChanged }
        try Task.checkCancellation()
    }

    private func decodedPayload(_ record: CKRecord) throws -> CloudSyncSnapshot {
        guard record.recordType == Self.recordType,
              record.recordID == recordID,
              let data = record[Self.payloadField] as? Data else { throw PrivateCloudTransportError.invalidPayload }
        do { return try CloudSyncSnapshot.decode(data) }
        catch { throw PrivateCloudTransportError.invalidPayload }
    }

    private func receipt(_ record: CKRecord, payload: CloudSyncSnapshot, accountID: String) -> PrivateCloudReceipt {
        PrivateCloudReceipt(accountID: accountID, payload: payload, verifiedAt: Date(), modifiedAt: record.modificationDate)
    }

    private func configuration() -> CKOperation.Configuration {
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .utility
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        return configuration
    }

    private func fetchRecord() async throws -> CKRecord? {
        let operation = CKFetchRecordsOperation(recordIDs: [recordID])
        operation.configuration = configuration()
        operation.desiredKeys = [Self.payloadField]
        let recordResult = CloudResultBox<CKRecord>()
        let request = CloudRequest<CKRecord?>()
        operation.perRecordResultBlock = { _, result in recordResult.set(result) }
        operation.fetchRecordsResultBlock = { result in
            if let record = recordResult.value() {
                switch record {
                case .success(let value): request.finish(.success(value))
                case .failure(let error) where (error as? CKError)?.code == .unknownItem: request.finish(.success(nil))
                case .failure(let error): request.finish(.failure(error))
                }
            } else {
                switch result {
                case .success: request.finish(.failure(PrivateCloudTransportError.invalidPayload))
                case .failure(let error) where (error as? CKError)?.code == .unknownItem: request.finish(.success(nil))
                case .failure(let error): request.finish(.failure(error))
                }
            }
        }
        return try await execute(operation, request: request)
    }

    private func saveRecord(_ record: CKRecord) async throws {
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        operation.configuration = configuration()
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = false // The default private zone need not be atomic.
        let recordResult = CloudResultBox<CKRecord>()
        let request = CloudRequest<Void>()
        operation.perRecordSaveBlock = { _, result in recordResult.set(result) }
        operation.modifyRecordsResultBlock = { result in
            if let record = recordResult.value() {
                request.finish(record.map { _ in () })
            } else {
                switch result {
                case .success: request.finish(.failure(PrivateCloudTransportError.invalidPayload))
                case .failure(let error): request.finish(.failure(error))
                }
            }
        }
        try await execute(operation, request: request)
    }

    private func execute<Value: Sendable>(_ operation: CKDatabaseOperation, request: CloudRequest<Value>) async throws -> Value {
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(40)) } catch { return }
            request.finish(.failure(PrivateCloudTransportError.unavailable(retryAfter: nil)))
            operation.cancel()
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                database.add(operation)
            }
        } onCancel: {
            request.finish(.failure(CancellationError()))
            operation.cancel()
        }
    }

    /// Container account callbacks aren't CKOperations, so give their awaiting
    /// caller the same finite budget without blocking cancellation or Settings.
    private func boundedRequest<Value: Sendable>(_ start: (CloudRequest<Value>) -> Void) async throws -> Value {
        let request = CloudRequest<Value>()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(40)) } catch { return }
            request.finish(.failure(PrivateCloudTransportError.unavailable(retryAfter: nil)))
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                start(request)
            }
        } onCancel: { request.finish(.failure(CancellationError())) }
    }

    private static func isConflict(_ error: Error) -> Bool {
        guard let cloud = error as? CKError else { return false }
        if cloud.code == .serverRecordChanged { return true }
        return cloud.partialErrorsByItemID?.values.contains(where: isConflict) ?? false
    }

    private func sanitized(_ error: Error) -> Error {
        if error is CancellationError || error is PrivateCloudTransportError { return error }
        if error is CloudSyncSnapshotError { return PrivateCloudTransportError.invalidPayload }
        guard let cloud = error as? CKError else { return PrivateCloudTransportError.unavailable(retryAfter: nil) }
        lastCloudErrorCode = cloud.errorCode
        if Self.isConflict(cloud) { return PrivateCloudTransportError.conflict }
        if cloud.code == .quotaExceeded { return PrivateCloudTransportError.quotaExceeded }
        if cloud.code == .notAuthenticated { return PrivateCloudTransportError.accountUnavailable }
        if cloud.code == .operationCancelled { return CancellationError() }
        let retry = cloud.retryAfterSeconds.flatMap { $0.isFinite && $0 > 0 ? min($0, 3_600) : nil }
        return PrivateCloudTransportError.unavailable(retryAfter: retry)
    }
}

/// Completion and cancellation can race. These two small locked cells ensure
/// exactly one resume and avoid capturing mutable callback state unsafely.
private final class CloudRequest<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class CloudResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    func set(_ result: Result<Value, any Error>) { lock.withLock { self.result = result } }
    func value() -> Result<Value, any Error>? { lock.withLock { result } }
}
