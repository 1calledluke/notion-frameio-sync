import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var coordinator: Coordinator!
    private var settingsController: SettingsWindowController?

    // Menu items that need dynamic updates
    private let statusMenuItem   = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private var activityMenuItems: [NSMenuItem] = []
    private var pauseMenuItem: NSMenuItem!
    private var menu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = Coordinator()
        coordinator.onActivityChanged = { [weak self] in self?.refreshMenu() }

        setupStatusItem()

        coordinator.start()
        LoginItem.enable()
        refreshMenu()
        Log("AppDelegate: launched")

        // Register to receive the Adobe IMS OAuth redirect URI
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    // MARK: - URL scheme handler (Adobe IMS OAuth callback)

    @objc @MainActor private func handleGetURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            Log("AppDelegate: received malformed URL event")
            return
        }
        Log("AppDelegate: received URL — \(urlString)")
        AuthManager.shared.handleCallbackURL(url)
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(needsAttention: false)

        menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        // Recent activity section (up to 5 items)
        for _ in 0..<5 {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.isHidden = true
            activityMenuItems.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        pauseMenuItem = NSMenuItem(title: "Pause Watcher",
                                   target: self, action: #selector(togglePause),
                                   keyEquivalent: "")
        menu.addItem(pauseMenuItem)

        menu.addItem(NSMenuItem(title: "Settings…",
                                target: self, action: #selector(openSettings),
                                keyEquivalent: ","))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Exports Syncer",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func setIcon(needsAttention: Bool) {
        let name = needsAttention
            ? "exclamationmark.triangle.fill"
            : "arrow.triangle.2.circlepath"
        statusItem.button?.image = NSImage(systemSymbolName: name,
                                            accessibilityDescription: "Exports Syncer")
        if needsAttention {
            statusItem.button?.image?.isTemplate = false
        }
    }

    private func refreshMenu() {
        if coordinator.needsAttention {
            setIcon(needsAttention: true)
            statusMenuItem.title = "⚠ \(coordinator.attentionReason)"
        } else if coordinator.isPaused {
            setIcon(needsAttention: false)
            statusMenuItem.title = "Paused"
        } else {
            setIcon(needsAttention: false)
            statusMenuItem.title = coordinator.config.isConfigured
                ? "Watching for exports…"
                : "Not configured — open Settings"
        }

        pauseMenuItem.title = coordinator.isPaused ? "Resume Watcher" : "Pause Watcher"

        let recent = Logger.shared.recent.suffix(5).reversed()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"

        for (i, item) in activityMenuItems.enumerated() {
            if i < recent.count {
                let entry = Array(recent)[i]
                item.title = "[\(dateFormatter.string(from: entry.date))] \(entry.message)"
                item.isHidden = false
            } else {
                item.isHidden = true
            }
        }
    }

    // MARK: - Actions

    @objc private func togglePause() {
        if coordinator.isPaused { coordinator.resume() } else { coordinator.pause() }
    }

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(coordinator: coordinator)
        }
        settingsController?.show()
    }

}

// Convenience NSMenuItem initializer with target
extension NSMenuItem {
    convenience init(title: String, target: AnyObject?, action: Selector?, keyEquivalent: String) {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        self.target = target
    }
}
