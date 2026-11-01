import AppKit
import Combine

/// Keeps the clipboard history in memory and on disk:
///   ~/Library/Application Support/ClipHistory/history.json      – entry metadata
///   ~/Library/Application Support/ClipHistory/items/<id>.plist  – raw pasteboard payload
///   ~/Library/Application Support/ClipHistory/items/<id>.png    – thumbnail
@MainActor
final class HistoryStore: ObservableObject {
    /// Newest first.
    @Published private(set) var entries: [ClipEntry] = []

    var maxItems: Int {
        didSet {
            UserDefaults.standard.set(maxItems, forKey: Self.maxItemsKey)
            trim()
            save()
        }
    }

    static let maxItemsKey = "maxItems"
    static let sizeOptions = [25, 50, 100, 200]

    private let directory: URL
    private let itemsDirectory: URL
    private let ioQueue = DispatchQueue(label: "ClipHistory.io", qos: .utility)
    private let thumbnailCache = NSCache<NSUUID, NSImage>()

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipHistory", isDirectory: true)
    }

    init(directory: URL = HistoryStore.defaultDirectory) {
        let stored = UserDefaults.standard.integer(forKey: Self.maxItemsKey)
        maxItems = stored > 0 ? stored : 50

        self.directory = directory
        itemsDirectory = directory.appendingPathComponent("items", isDirectory: true)
        try? FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Mutations

    func add(_ capture: ClipCapture) {
        var entry = capture.entry
        if let index = entries.firstIndex(where: { $0.contentHash == entry.contentHash }) {
            // Same content copied again: replace the payload, keep identity and pin, move to top.
            let existing = entries.remove(at: index)
            entry = ClipEntry(
                id: existing.id, kind: entry.kind, text: entry.text, detail: entry.detail,
                hasThumbnail: entry.hasThumbnail, sourceBundleID: entry.sourceBundleID,
                sourceName: entry.sourceName, date: entry.date, pinned: existing.pinned,
                contentHash: entry.contentHash, byteCount: entry.byteCount
            )
            thumbnailCache.removeObject(forKey: entry.id as NSUUID)
        }
        writeFiles(id: entry.id, payload: capture.payload, thumbnail: capture.thumbnailPNG)
        entries.insert(entry, at: 0)
        trim()
        save()
    }

    /// Marks an entry as just used (moves it to the top).
    func touch(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries.remove(at: index)
        entry.date = Date()
        entries.insert(entry, at: 0)
        save()
    }

    func togglePin(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].pinned.toggle()
        trim()
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        deleteFiles(id: id)
        save()
    }

    /// Removes everything except pinned entries (like Windows' "Clear all").
    func clearUnpinned() {
        let removed = entries.filter { !$0.pinned }
        entries.removeAll { !$0.pinned }
        removed.forEach { deleteFiles(id: $0.id) }
        save()
    }

    // MARK: - Reading

    func payload(for id: UUID) -> ClipPayload? {
        guard let data = try? Data(contentsOf: payloadURL(id)) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? ClipPayload
    }

    func thumbnail(for entry: ClipEntry) -> NSImage? {
        guard entry.hasThumbnail else { return nil }
        if let cached = thumbnailCache.object(forKey: entry.id as NSUUID) { return cached }
        guard let image = NSImage(contentsOf: thumbnailURL(entry.id)) else { return nil }
        thumbnailCache.setObject(image, forKey: entry.id as NSUUID)
        return image
    }

    /// Puts an entry back on the system pasteboard. Returns false if its payload is gone.
    @discardableResult
    func writeToPasteboard(_ entry: ClipEntry, plainText: Bool) -> Bool {
        guard let payload = payload(for: entry.id) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()

        if plainText, let string = Self.plainText(from: payload, entry: entry) {
            return pb.setString(string, forType: .string)
        }
        let items: [NSPasteboardItem] = payload.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        return pb.writeObjects(items)
    }

    private static func plainText(from payload: ClipPayload, entry: ClipEntry) -> String? {
        if entry.kind == .files {
            let paths = payload.compactMap { $0["public.file-url"] }
                .compactMap { String(data: $0, encoding: .utf8) }
                .compactMap { URL(string: $0)?.path }
            return paths.isEmpty ? nil : paths.joined(separator: "\n")
        }
        let strings = payload.compactMap { $0["public.utf8-plain-text"] }.compactMap { String(data: $0, encoding: .utf8) }
        return strings.isEmpty ? nil : strings.joined(separator: "\n")
    }

    // MARK: - Persistence

    /// Blocks until queued disk writes finish (call before quitting).
    func flush() {
        ioQueue.sync {}
    }

    private var historyURL: URL { directory.appendingPathComponent("history.json") }
    private func payloadURL(_ id: UUID) -> URL { itemsDirectory.appendingPathComponent("\(id.uuidString).plist") }
    private func thumbnailURL(_ id: UUID) -> URL { itemsDirectory.appendingPathComponent("\(id.uuidString).png") }

    private func load() {
        guard let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder().decode([ClipEntry].self, from: data) else { return }
        let fm = FileManager.default
        entries = decoded.filter { fm.fileExists(atPath: payloadURL($0.id).path) }

        // Remove files that no longer belong to any entry.
        let known = Set(entries.map(\.id.uuidString))
        let files = (try? fm.contentsOfDirectory(at: itemsDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !known.contains(file.deletingPathExtension().lastPathComponent) {
            try? fm.removeItem(at: file)
        }
    }

    private func save() {
        let snapshot = entries
        let url = historyURL
        ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func trim() {
        var unpinned = entries.filter { !$0.pinned }.count
        while unpinned > maxItems, let index = entries.lastIndex(where: { !$0.pinned }) {
            deleteFiles(id: entries[index].id)
            entries.remove(at: index)
            unpinned -= 1
        }
    }

    private func writeFiles(id: UUID, payload: ClipPayload, thumbnail: Data?) {
        let payloadURL = payloadURL(id)
        let thumbURL = thumbnailURL(id)
        // Payload is written synchronously so an immediate paste can read it back.
        if let data = try? PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0) {
            try? data.write(to: payloadURL, options: .atomic)
        }
        ioQueue.async {
            if let thumbnail {
                try? thumbnail.write(to: thumbURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: thumbURL)
            }
        }
        if let thumbnail, let image = NSImage(data: thumbnail) {
            thumbnailCache.setObject(image, forKey: id as NSUUID)
        }
    }

    private func deleteFiles(id: UUID) {
        thumbnailCache.removeObject(forKey: id as NSUUID)
        let urls = [payloadURL(id), thumbnailURL(id)]
        ioQueue.async {
            urls.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }
}
