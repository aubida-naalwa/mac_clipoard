import AppKit
import ServiceManagement

@main
@MainActor
enum ClipHistoryApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = HistoryStore()
    private let monitor = ClipboardMonitor()
    private let hotKey = GlobalHotKey()
    private lazy var panel = PanelController(store: store)
    private var statusItem: NSStatusItem?
    private var shortcut = Shortcut.load()

    private static let pausedKey = "paused"
    private static let welcomeKey = "didShowWelcome"

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.isPaused = UserDefaults.standard.bool(forKey: Self.pausedKey)
        monitor.onCapture = { [weak self] capture in self?.store.add(capture) }
        monitor.start()

        panel.onPaste = { [weak self] entry, plainText in self?.paste(entry, plainText: plainText) }
        panel.onAccessibilityHelp = { [weak self] in self?.showAccessibilityHelp() }
        hotKey.onPress = { [weak self] in self?.panel.toggle() }
        registerHotKey()

        setUpStatusItem()

        if CommandLine.arguments.contains("--show") {
            panel.show()
        } else {
            DispatchQueue.main.async { self.showWelcomeIfNeeded() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
    }

    // MARK: - Pasting

    private func paste(_ entry: ClipEntry, plainText: Bool) {
        guard store.writeToPasteboard(entry, plainText: plainText) else {
            NSSound.beep()
            store.remove(entry.id)
            return
        }
        monitor.skipCurrentContents()
        store.touch(entry.id)

        guard Paster.isTrusted else {
            // Without Accessibility we can only put it on the clipboard; the user presses ⌘V.
            // The panel footer already explains how to fix it, so don't pop the system prompt here.
            return
        }
        // Give the target app a moment to get keyboard focus back from our panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Paster.pressCommandV()
        }
    }

    private func registerHotKey() {
        guard hotKey.register(shortcut) else {
            showAlert(
                title: "Couldn't register \(shortcut.display)",
                message: "Another app may already use this shortcut. Pick a different one from the ClipHistory menu bar icon → Shortcut."
            )
            return
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "ClipHistory")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "ClipHistory"
        item.button?.appearsDisabled = monitor.isPaused
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let show = addItem(to: menu, title: "Show Clipboard History", action: #selector(showPanel))
        show.keyEquivalent = "v"
        show.keyEquivalentModifierMask = shortcut.menuModifiers

        menu.addItem(.separator())

        addItem(to: menu, title: "Pause Recording", action: #selector(togglePause)).state = monitor.isPaused ? .on : .off
        addItem(to: menu, title: "Clear History", action: #selector(clearHistory))

        menu.addItem(.separator())

        let shortcutMenu = NSMenu()
        for (index, preset) in Shortcut.presets.enumerated() {
            let item = addItem(to: shortcutMenu, title: preset.display, action: #selector(selectShortcut(_:)))
            item.tag = index
            item.state = preset == shortcut ? .on : .off
        }
        menu.addItem(withTitle: "Shortcut", action: nil, keyEquivalent: "").submenu = shortcutMenu

        let sizeMenu = NSMenu()
        for size in HistoryStore.sizeOptions {
            let item = addItem(to: sizeMenu, title: "\(size) items", action: #selector(selectHistorySize(_:)))
            item.tag = size
            item.state = size == store.maxItems ? .on : .off
        }
        menu.addItem(withTitle: "History Size", action: nil, keyEquivalent: "").submenu = sizeMenu

        addItem(to: menu, title: "Open at Login", action: #selector(toggleLaunchAtLogin)).state =
            SMAppService.mainApp.status == .enabled ? .on : .off

        if !Paster.isTrusted {
            menu.addItem(.separator())
            addItem(to: menu, title: "Allow Accessibility Access…", action: #selector(grantAccessibility))
        }

        menu.addItem(.separator())
        addItem(to: menu, title: "About ClipHistory", action: #selector(showAbout))
        addItem(to: menu, title: "Quit ClipHistory", action: #selector(quit)).keyEquivalent = "q"
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func showPanel() {
        // Let the menu finish closing so focus is back in the previous app.
        DispatchQueue.main.async { self.panel.show() }
    }

    @objc private func togglePause() {
        monitor.isPaused.toggle()
        UserDefaults.standard.set(monitor.isPaused, forKey: Self.pausedKey)
        statusItem?.button?.appearsDisabled = monitor.isPaused
    }

    @objc private func clearHistory() {
        store.clearUnpinned()
    }

    @objc private func selectShortcut(_ sender: NSMenuItem) {
        shortcut = Shortcut.presets[sender.tag]
        shortcut.save()
        registerHotKey()
    }

    @objc private func selectHistorySize(_ sender: NSMenuItem) {
        store.maxItems = sender.tag
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert(title: "Couldn't change Open at Login", message: error.localizedDescription)
        }
    }

    @objc private func grantAccessibility() {
        showAccessibilityHelp()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Alerts

    private func showWelcomeIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.welcomeKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.welcomeKey)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ClipHistory is running"
        alert.informativeText = """
        Press \(shortcut.display) anywhere to open your clipboard history, then pick an item to paste it.

        To paste straight into the app you're using, ClipHistory needs Accessibility access. \
        Without it, the item is copied and you press ⌘V yourself.
        """
        if Paster.isTrusted {
            alert.addButton(withTitle: "Got It")
            alert.runModal()
        } else {
            alert.addButton(withTitle: "Allow Accessibility…")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                Paster.requestTrust()
            }
        }
    }

    /// macOS ties the permission to the exact build, so a switch that is already on can belong
    /// to an older copy of the app. Explain that case instead of re-showing the system prompt.
    private func showAccessibilityHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow ClipHistory to paste"
        alert.informativeText = """
        In Privacy & Security → Accessibility, turn on ClipHistory. If it isn't in the list, click + and choose it from Applications.

        Already turned on? The permission belongs to an older build of ClipHistory. Select ClipHistory, click − to remove it, then click + and add it again.
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Paster.openAccessibilitySettings()
        }
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
