import Foundation
import Testing
@testable import PulseWidgetData

struct CloudSyncPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let publisherID = UUID(uuidString: "BE6580DA-E9DF-41D8-AB35-AD21871F461F")!

    private func payload(publisherID: UUID? = nil, age: TimeInterval = 0, empty: Bool = false) throws -> CloudSyncSnapshot {
        let date = now.addingTimeInterval(-age)
        return try CloudSyncSnapshot.prepared(publisherID: publisherID ?? self.publisherID, snapshot:
            WidgetSnapshot(generatedAt: date, projects: empty ? [] : [
                WidgetProject(id: UUID(), name: "Studio", symbol: "calendar", ranges: [
                    WidgetRange(rawValue: "7d", title: "7d", measuredAt: date, metrics: [
                        WidgetMetric(id: UUID(), label: "Accounts", value: "12")
                    ])
                ])
            ]), now: now)
    }

    private func decision(enabled: Bool = true, boundAccountID: String? = "account-a", actualAccountID: String = "account-a",
                          local: CloudSyncSnapshot? = nil, remote: CloudSyncSnapshot? = nil,
                          replacingPublisherID: UUID? = nil) throws -> CloudSyncDecision {
        try CloudSyncPolicy.decision(enabled: enabled, boundAccountID: boundAccountID, actualAccountID: actualAccountID,
                                     local: local, remote: remote, publisherID: publisherID,
                                     replacingPublisherID: replacingPublisherID, now: now)
    }

    @Test func disabledSyncNeverPublishesOrReceives() throws {
        let local = try payload(), remote = try payload(publisherID: UUID())
        #expect(try decision(enabled: false, boundAccountID: nil, actualAccountID: "account-b", local: local, remote: remote) == .off)
    }

    @Test func missingChangedAndEmptyAccountIdentitiesPauseBeforeAnyDataCanMove() throws {
        let local = try payload(), remote = try payload()
        #expect(try decision(boundAccountID: nil, local: local, remote: remote) == .pausedAccountChange)
        #expect(try decision(actualAccountID: "account-b", local: local, remote: remote) == .pausedAccountChange)
        #expect(try decision(boundAccountID: "", actualAccountID: "", local: local, remote: remote) == .pausedAccountChange)
        #expect(try decision(boundAccountID: " ", actualAccountID: " ", local: local, remote: remote) == .pausedAccountChange)
    }

    @Test func emptyReceiversNeverEraseAnyPublisherEvenWithAReplacementRequest() throws {
        let remote = try payload(publisherID: UUID())
        #expect(try decision() == .unchanged(nil))
        #expect(try decision(remote: remote) == .receive(remote))
        #expect(try decision(remote: remote, replacingPublisherID: remote.publisherID) == .receive(remote))
        let ownRemote = try payload()
        #expect(try decision(remote: ownRemote) == .receive(ownRemote))
    }

    @Test func firstCollectorPublishesAndOnlyNewerOwnedSummariesReplaceTheServer() throws {
        let older = try payload(age: 60), newer = try payload()
        #expect(try decision(local: newer) == .publish(newer, replacingPublisherID: nil))
        #expect(try decision(local: newer, remote: older) == .publish(newer, replacingPublisherID: nil))
        #expect(try decision(local: older, remote: newer) == .receive(newer))
        #expect(try decision(local: newer, remote: newer) == .unchanged(newer))
        let equalTime = try payload()
        #expect(try decision(local: equalTime, remote: newer) == .receive(newer))
    }

    @Test func ownershipTransferRequiresTheExactCurrentPublisher() throws {
        let local = try payload(), remote = try payload(publisherID: UUID())
        #expect(try decision(local: local, remote: remote) == .receive(remote))
        #expect(try decision(local: local, remote: remote, replacingPublisherID: UUID()) == .receive(remote))
        #expect(try decision(local: local, remote: remote, replacingPublisherID: remote.publisherID)
                == .publish(local, replacingPublisherID: remote.publisherID))
        let newerOwner = try payload(publisherID: UUID())
        #expect(try decision(local: local, remote: newerOwner, replacingPublisherID: remote.publisherID) == .receive(newerOwner))
    }

    @Test func anOwnedExplicitEmptySnapshotCanRemoveDeletedProjectsWithoutStaleRevival() throws {
        let retained = try payload(age: 60), empty = try payload(empty: true)
        #expect(try decision(local: empty, remote: retained) == .publish(empty, replacingPublisherID: nil))
        #expect(try decision(local: retained, remote: empty) == .receive(empty))
    }

    @Test func invalidSummariesAndIncorrectLocalIdentityFailClosed() throws {
        let otherMac = try payload(publisherID: UUID())
        #expect(throws: CloudSyncSnapshotError.publisherMismatch) { try decision(local: otherMac) }
        let invalid = CloudSyncSnapshot(schemaVersion: 2, publisherID: publisherID, snapshot: WidgetSnapshot(generatedAt: now))
        #expect(throws: CloudSyncSnapshotError.unsupportedVersion) { try decision(remote: invalid) }
        #expect(try decision(enabled: false, remote: invalid) == .off)
        #expect(try decision(actualAccountID: "account-b", remote: invalid) == .pausedAccountChange)
    }
}
