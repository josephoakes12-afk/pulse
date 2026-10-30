import Foundation

/// Removing a copy replaces only the confirmed publisher's data with a small
/// empty marker. A fresh publisher identity prevents old collectors from
/// republishing automatically, including when they have a clock skew.
public enum CloudSyncRemovalPolicy {
    public static func marker(current: CloudSyncSnapshot?, confirmedPublisherID: UUID,
                              removalPublisherID: UUID = UUID(), now: Date = Date()) throws -> CloudSyncSnapshot {
        try current?.validate(now: now)
        if let current, current.publisherID != confirmedPublisherID {
            throw CloudSyncSnapshotError.publisherMismatch
        }
        guard removalPublisherID != confirmedPublisherID else { throw CloudSyncSnapshotError.invalidSnapshot }
        let marker = CloudSyncSnapshot(publisherID: removalPublisherID,
            snapshot: WidgetSnapshot(generatedAt: now, defaultRangeRawValue: "7d", projects: []), isCleared: true)
        try marker.validate(now: now)
        return marker
    }
}
