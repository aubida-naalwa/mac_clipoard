import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// State shown by the history panel.
@MainActor
final class PanelModel: ObservableObject {
    @Published var query = "" { didSet { refilter() } }
    @Published private(set) var items: [ClipEntry] = []
    @Published var selectedID: UUID?
    @Published private(set) var openedAt = Date()
    @Published private(set) var needsAccessibility = false

    private var all: [ClipEntry] = []

    var selected: ClipEntry? { items.first { $0.id == selectedID } }

    func update(entries: [ClipEntry]) {
        // Pinned items stay at the top; everything else is newest first.
        all = entries.filter(\.pinned) + entries.filter { !$0.pinned }
        refilter()
    }

    func prepareForShow() {
        query = ""
        openedAt = Date()
        selectedID = items.first?.id
        needsAccessibility = !Paster.isTrusted
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? -1
        selectedID = items[min(max(current + delta, 0), items.count - 1)].id
    }

    private func refilter() {
        let q = query.trimmingCharacters(in: .whitespaces)
        items = q.isEmpty ? all : all.filter {
            $0.text.localizedCaseInsensitiveContains(q) || ($0.sourceName?.localizedCaseInsensitiveContains(q) ?? false)
        }
        if let selectedID, items.contains(where: { $0.id == selectedID }) { return }
        selectedID = items.first?.id
    }
}

struct PanelActions {
    var paste: (ClipEntry, _ plainText: Bool) -> Void
    var togglePin: (ClipEntry) -> Void
    var delete: (ClipEntry) -> Void
    var clearAll: () -> Void
    var openAccessibilitySettings: () -> Void
}

/// Floating panel that can take keyboard input without activating ClipHistory,
/// so the app you were typing in stays frontmost and receives the paste.
final class HistoryPanel: NSPanel {
    static let cornerRadius: CGFloat = 12

    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        contentView = effect
    }

    func setRootView<Content: View>(_ view: Content) {
        guard let container = contentView else { return }
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let panelSize = NSSize(width: 380, height: 480)

    let model = PanelModel()
    var onPaste: ((ClipEntry, Bool) -> Void)?
    var onAccessibilityHelp: (() -> Void)?

    private let store: HistoryStore
    private let panel = HistoryPanel(size: PanelController.panelSize)
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    private(set) var isVisible = false

    init(store: HistoryStore) {
        self.store = store
        super.init()
        panel.delegate = self

        let actions = PanelActions(
            paste: { [weak self] entry, plain in self?.paste(entry, plainText: plain) },
            togglePin: { [weak self] entry in self?.store.togglePin(entry.id) },
            delete: { [weak self] entry in self?.delete(entry) },
            clearAll: { [weak self] in self?.store.clearUnpinned() },
            openAccessibilitySettings: { [weak self] in
                self?.hide()
                self?.onAccessibilityHelp?()
            }
        )
        panel.setRootView(HistoryView(model: model, store: store, actions: actions))

        store.$entries
            .sink { [weak self] entries in self?.model.update(entries: entries) }
            .store(in: &cancellables)

        // Switching apps (⌘Tab, Dock click…) dismisses the panel, like a menu.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in self?.hide() }
            .store(in: &cancellables)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        model.prepareForShow()
        panel.setFrameOrigin(origin(for: panel.frame.size, near: CaretLocator.caretRect()))
        panel.orderFrontRegardless()
        panel.makeKey()
        installKeyMonitor()
        isVisible = true
    }

    func hide() {
        // orderOut makes the panel resign key, which calls hide() again; the flag stops that loop.
        guard isVisible else { return }
        isVisible = false
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: - Actions

    private func paste(_ entry: ClipEntry, plainText: Bool) {
        hide()
        onPaste?(entry, plainText)
    }

    private func delete(_ entry: ClipEntry) {
        let index = model.items.firstIndex { $0.id == entry.id }
        store.remove(entry.id)
        if let index, !model.items.isEmpty {
            model.selectedID = model.items[min(index, model.items.count - 1)].id
        }
    }

    // MARK: - Placement

    /// Opens under the text cursor when we can find it, otherwise at the mouse pointer.
    private func origin(for size: NSSize, near caret: NSRect?) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let anchor = caret ?? NSRect(x: mouse.x, y: mouse.y, width: 0, height: 0)
        let screen = NSScreen.screens.first { NSMouseInRect(anchor.origin, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        let margin: CGFloat = 6

        var x = anchor.minX
        var y = anchor.minY - size.height - margin
        if y < frame.minY + margin {
            y = anchor.maxY + margin // not enough room below: open above
        }
        x = min(max(x, frame.minX + margin), frame.maxX - size.width - margin)
        y = min(max(y, frame.minY + margin), frame.maxY - size.height - margin)
        return NSPoint(x: x, y: y)
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            self.handleKey(event)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)

        switch Int(event.keyCode) {
        case kVK_Escape:
            if model.query.isEmpty { hide() } else { model.query = "" }
            return
        case kVK_DownArrow:
            model.moveSelection(by: command ? 100_000 : 1)
            return
        case kVK_UpArrow:
            model.moveSelection(by: command ? -100_000 : -1)
            return
        case kVK_PageDown:
            model.moveSelection(by: 5)
            return
        case kVK_PageUp:
            model.moveSelection(by: -5)
            return
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let entry = model.selected {
                paste(entry, plainText: flags.contains(.shift) || flags.contains(.option))
            }
            return
        case kVK_Delete, kVK_ForwardDelete:
            if command || (event.keyCode == kVK_ForwardDelete && model.query.isEmpty) {
                if let entry = model.selected { delete(entry) }
            } else if flags.contains(.option) {
                model.query = Self.droppingLastWord(model.query)
            } else if !model.query.isEmpty {
                model.query.removeLast()
            }
            return
        case kVK_Tab:
            return
        default:
            break
        }

        if command {
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if let digit = Int(key), (1...9).contains(digit), digit <= model.items.count {
                paste(model.items[digit - 1], plainText: flags.contains(.shift))
            } else if key == "p", let entry = model.selected {
                store.togglePin(entry.id)
            } else if key == "w" || key == "q" {
                hide()
            }
            return
        }
        if flags.contains(.control) { return }

        // Anything printable goes into the search query.
        guard let characters = event.characters, !characters.isEmpty else { return }
        let printable = characters.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        }
        if printable { model.query += characters }
    }

    private static func droppingLastWord(_ text: String) -> String {
        var result = text
        while result.last?.isWhitespace == true { result.removeLast() }
        while let last = result.last, !last.isWhitespace { result.removeLast() }
        return result
    }
}
