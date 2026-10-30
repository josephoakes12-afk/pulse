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
        if ProcessInfo.processInfo.arguments.contains("--light") { popover.appearance = NSAppearance(named: .aqua) }
        if ProcessInfo.processInfo.arguments.contains("--dark") { popover.appearance = NSAppearance(named: .darkAqua) }
        let controller = NSHostingController(rootView: PulsePanel(store: .shared))
        controller.view.appearance = popover.appearance
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        Task {
            await AppStore.shared.start()
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--show-panel") || (AppStore.shared.connections.isEmpty && !arguments.contains("--preview") && !arguments.contains("--connections")) {
                showPanel()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--preview") { AppWindows.showPreview(store: .shared) }
        if ProcessInfo.processInfo.arguments.contains("--connections") { AppWindows.showConnections(store: .shared) }
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
        showPanel()
        return false
    }

    @objc private func showConnections() { AppWindows.showConnections(store: .shared) }

    private func configureMenus() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Pulse")
        applicationMenu.addItem(withTitle: "About Pulse", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
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

    static func showConnections(store: AppStore) {
        if connections == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 470), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Pulse Settings"
            window.contentView = NSHostingView(rootView: ConnectionsView(store: store))
            window.minSize = NSSize(width: 600, height: 440)
            window.isReleasedWhenClosed = false
            window.center()
            connections = window
        }
        connections?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showPreview(store: AppStore) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 364, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pulse"
        window.contentView = NSHostingView(rootView: PulsePanel(store: store))
        window.isReleasedWhenClosed = false
        window.center()
        preview = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
