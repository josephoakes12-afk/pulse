import AppKit
import SwiftUI

@main
enum PulseApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = PulseAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class PulseAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var panelObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenus()
        if ProcessInfo.processInfo.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if ProcessInfo.processInfo.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Pulse")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePanel)
            button.toolTip = "Pulse — your projects at a glance"
        }
        statusItem = item
        popover.behavior = .transient
        // SwiftUI supplies each intermediate content height. AppKit must not
        // start a second resize animation for every one of those frames.
        popover.animates = false
        if ProcessInfo.processInfo.arguments.contains("--light") { popover.appearance = NSAppearance(named: .aqua) }
        if ProcessInfo.processInfo.arguments.contains("--dark") { popover.appearance = NSAppearance(named: .darkAqua) }
        let controller = NSHostingController(rootView: PulsePanel(store: .shared))
        controller.view.appearance = popover.appearance
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        panelObserver = NotificationCenter.default.addObserver(forName: .pulseShowPanel, object: nil, queue: .main) { [weak self] _ in
            // Let the setup window finish closing and its mouse event finish
            // before showing a transient popover, which would otherwise dismiss.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.showPanel() }
        }
        Task {
            await AppStore.shared.start()
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--show-panel") || (AppStore.shared.connections.isEmpty && !arguments.contains("--preview") && !arguments.contains("--connections") && !arguments.contains("--add-project")) {
                showPanel()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--preview") { AppWindows.showPreview(store: .shared) }
        if ProcessInfo.processInfo.arguments.contains("--connections") { AppWindows.showConnections(store: .shared) }
        if ProcessInfo.processInfo.arguments.contains("--add-project") { AppWindows.showAddProject(store: .shared) }
    }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) } else { showPanel() }
    }

    private func showPanel() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && !popover.isShown { showPanel() }
        return false
    }

    @objc private func showConnections() { AppWindows.showConnections(store: .shared) }
    @objc private func addProject() { AppWindows.showAddProject(store: .shared) }

    private func configureMenus() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Pulse")
        applicationMenu.addItem(withTitle: "About Pulse", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        let add = applicationMenu.addItem(withTitle: "Add Project…", action: #selector(addProject), keyEquivalent: "n")
        add.target = self
        let settings = applicationMenu.addItem(withTitle: "Settings…", action: #selector(showConnections), keyEquivalent: ",")
        settings.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Hide Pulse", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        applicationMenu.addItem(withTitle: "Quit Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
}

@MainActor
enum AppWindows {
    private static var connections: NSWindow?
    private static var preview: NSWindow?
    private static var addProject: NSWindow?

    static func showAddProject(store: AppStore) {
        if addProject?.isVisible != true {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Add Project"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AddProjectView(store: store) { [weak window] in window?.close() })
            window.center()
            addProject = window
        }
        addProject?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showConnections(store: AppStore, selecting projectID: UUID? = nil) {
        if connections == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 470), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Pulse Settings"
            window.contentView = NSHostingView(rootView: ConnectionsView(store: store, initialSelection: projectID))
            window.minSize = NSSize(width: 600, height: 440)
            window.isReleasedWhenClosed = false
            window.center()
            connections = window
        }
        connections?.makeKeyAndOrderFront(nil)
        if let projectID { NotificationCenter.default.post(name: .pulseSelectProject, object: projectID) }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showPreview(store: AppStore) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 364, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pulse"
        let host = NSHostingView(rootView: PulsePanel(store: store)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.regularMaterial))
        // The review window is fixed. Keep its header anchored while the
        // compact panel changes size inside it.
        host.sizingOptions = []
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.center()
        preview = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
