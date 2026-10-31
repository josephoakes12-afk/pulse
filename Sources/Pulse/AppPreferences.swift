import AppKit
import Combine
import Foundation
import PulseCore
import ServiceManagement

@MainActor
final class AppPreferences: ObservableObject {
    @Published private(set) var openAtLogin = false
    @Published private(set) var loginRequiresApproval = false
    @Published private(set) var loginMessage: String?
    @Published private(set) var loginBusy = false
    @Published private(set) var checkingForUpdates = false
    @Published private(set) var updateMessage: String?
    @Published private(set) var availableReleaseURL: URL?
    let canConfigureLoginItem: Bool
    let canCheckForUpdates: Bool
    let versionLabel: String
    private let installedVersion: PulseAppVersion?
    private let releaseClient: PulseReleaseClient
    private var activation: AnyCancellable?

    init(bundle: Bundle = .main, releaseClient: PulseReleaseClient = PulseReleaseClient()) {
        self.releaseClient = releaseClient
        canCheckForUpdates = PulseDistribution(bundle: bundle).allowsDirectUpdates
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        installedVersion = PulseAppVersion(version: version, build: build)
        versionLabel = version.isEmpty ? "Development build" : version + (build.map { " (\($0))" } ?? "")
        let path = bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let allowed = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        let arguments = ProcessInfo.processInfo.arguments
        canConfigureLoginItem = path.pathExtension == "app" && allowed.contains(path.deletingLastPathComponent()) &&
            !arguments.contains("--demo") && !arguments.contains("--data-directory")
        refreshLoginStatus()
        activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.refreshLoginStatus() } }
    }

    /// Reading status never registers or changes a person's existing preference.
    func refreshLoginStatus() {
        guard canConfigureLoginItem else {
            loginMessage = "Move Pulse to Applications first."
            return
        }
        let status = SMAppService.mainApp.status
        openAtLogin = status == .enabled || status == .requiresApproval
        loginRequiresApproval = status == .requiresApproval
        switch status {
        case .enabled, .notRegistered: loginMessage = nil
        case .requiresApproval: loginMessage = "Allow Pulse in Login Items."
        case .notFound: loginMessage = "Reopen Pulse from Applications."
        @unknown default: loginMessage = "Couldn’t read Login Items."
        }
    }

    func setOpenAtLogin(_ enabled: Bool) async {
        guard canConfigureLoginItem, !loginBusy else { return }
        loginBusy = true
        defer { loginBusy = false }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
            } else { try await SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            if !loginRequiresApproval { loginMessage = "Couldn’t change Login Items. Try again in System Settings." }
        }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    func checkForUpdates() async {
        guard canCheckForUpdates, !checkingForUpdates else { return }
        guard let installedVersion else { updateMessage = "Version unavailable in this build."; return }
        checkingForUpdates = true
        updateMessage = "Checking…"
        availableReleaseURL = nil
        defer { checkingForUpdates = false }
        do {
            switch try await releaseClient.check(installed: installedVersion) {
            case .upToDate: updateMessage = "You’re up to date."
            case .unreleased: updateMessage = "No public download yet."
            case .available(let release):
                let build = release.version.build.map { " (\($0))" } ?? ""
                updateMessage = "Pulse \(release.version.marketingVersion)\(build) is available."
                availableReleaseURL = release.releaseURL
            }
        } catch is CancellationError { updateMessage = nil }
        catch { updateMessage = "Couldn’t check for updates. Try again later." }
    }

    func openAvailableRelease() {
        guard canCheckForUpdates, let availableReleaseURL else { return }
        if !NSWorkspace.shared.open(availableReleaseURL) { updateMessage = "Couldn’t open the download page." }
    }
}
