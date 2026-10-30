import Foundation

public enum CloudSyncDecision: Equatable, Sendable {
    case off
    case pausedAccountChange
    case receive(CloudSyncSnapshot)
    case publish(CloudSyncSnapshot, replacingPublisherID: UUID?)
    case unchanged(CloudSyncSnapshot?)
}

/// Publication is limited to one explicitly bound account and collecting Mac.
/// A receiver without local sources can read summaries but can never clear them.
public enum CloudSyncPolicy {
    public static func decision(enabled: Bool, boundAccountID: String?, actualAccountID: String,
                                local: CloudSyncSnapshot?, remote: CloudSyncSnapshot?, publisherID: UUID,
                                replacingPublisherID: UUID? = nil, now: Date = Date()) throws -> CloudSyncDecision {
        guard enabled else { return .off }
        guard let boundAccountID, !actualAccountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              boundAccountID == actualAccountID else { return .pausedAccountChange }

        if let local {
            try local.validate(now: now)
            guard local.publisherID == publisherID else { throw CloudSyncSnapshotError.publisherMismatch }
        }
        try remote?.validate(now: now)

        guard let local else {
            return remote.map(CloudSyncDecision.receive) ?? .unchanged(nil)
        }
        guard let remote else { return .publish(local, replacingPublisherID: nil) }

        guard remote.publisherID == publisherID else {
            // A stale takeover confirmation must not replace a different Mac
            // which acquired ownership after the confirmation was presented.
            return replacingPublisherID == remote.publisherID
                ? .publish(local, replacingPublisherID: remote.publisherID)
                : .receive(remote)
        }

        if local.snapshot.generatedAt > remote.snapshot.generatedAt {
            return .publish(local, replacingPublisherID: nil)
        }
        return local == remote ? .unchanged(remote) : .receive(remote)
    }
}
