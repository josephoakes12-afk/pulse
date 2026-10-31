import Foundation

/// Store builds use Apple's update channel. Unknown/source build values retain
/// the direct-download behavior so a fork doesn't silently lose update controls.
public enum PulseDistribution: String, Sendable {
    case direct
    case appStore = "app-store"

    public init(channel: String?) {
        self = channel == Self.appStore.rawValue ? .appStore : .direct
    }

    public init(bundle: Bundle) {
        self.init(channel: bundle.object(forInfoDictionaryKey: "PulseDistributionChannel") as? String)
    }

    public var allowsDirectUpdates: Bool { self == .direct }
}
