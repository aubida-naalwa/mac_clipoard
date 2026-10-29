import AppKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: PanelModel
    let store: HistoryStore
    let actions: PanelActions

    var body: some View {
        VStack(spacing: 0) {
            header
            SearchBar(query: model.query)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            Divider().opacity(0.6)
            if model.items.isEmpty {
                EmptyState(isSearching: !model.query.isEmpty)
            } else {
                list
            }
            Divider().opacity(0.6)
            footer
        }
        .frame(width: PanelController.panelSize.width, height: PanelController.panelSize.height)
        .overlay(
            RoundedRectangle(cornerRadius: HistoryPanel.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.clipboard")
                .foregroundStyle(.secondary)
            Text("Clipboard")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if model.items.contains(where: { !$0.pinned }) {
                Button("Clear all", action: actions.clearAll)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .help("Remove everything except pinned items")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, entry in
                        ClipRow(
                            entry: entry,
                            index: index,
                            isSelected: entry.id == model.selectedID,
                            store: store,
                            openedAt: model.openedAt,
                            actions: actions
                        )
                        .id(entry.id)
                    }
                }
                .padding(10)
            }
            .onChange(of: model.selectedID) { id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
            }
            .onChange(of: model.openedAt) { _ in
                if let first = model.items.first { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.needsAccessibility {
                Button(action: actions.openAccessibilitySettings) {
                    Label("Allow Accessibility access to paste directly", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                KeyHint(key: "↩", label: "Paste")
                KeyHint(key: "⇧↩", label: "Plain text")
                KeyHint(key: "⌘P", label: "Pin")
                KeyHint(key: "⌘⌫", label: "Delete")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct SearchBar: View {
    let query: String
    @State private var caretVisible = true

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            HStack(spacing: 1) {
                if !query.isEmpty {
                    Text(query).lineLimit(1).truncationMode(.head)
                }
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1.5, height: 14)
                    .opacity(caretVisible ? 1 : 0)
                if query.isEmpty {
                    Text("Type to search").foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever()) { caretVisible = false }
        }
    }
}

private struct EmptyState: View {
    let isSearching: Bool

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: isSearching ? "magnifyingglass" : "clipboard")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(isSearching ? "No matches" : "Nothing copied yet")
                .font(.system(size: 13, weight: .semibold))
            Text(isSearching ? "Try a different search." : "Copy text, links or images and\nthey'll show up here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Text(key).fontWeight(.semibold)
            Text(label)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }
}

private struct ClipRow: View {
    let entry: ClipEntry
    let index: Int
    let isSelected: Bool
    let store: HistoryStore
    let openedAt: Date
    let actions: PanelActions

    @State private var hovering = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            content
            meta
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(hovering ? 0.09 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.05), lineWidth: isSelected ? 1.5 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if hovering { hoverButtons.padding(6) }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { actions.paste(entry, false) }
        .contextMenu {
            Button("Paste") { actions.paste(entry, false) }
            if entry.kind != .image {
                Button("Paste as Plain Text") { actions.paste(entry, true) }
            }
            Divider()
            Button(entry.pinned ? "Unpin" : "Pin") { actions.togglePin(entry) }
            Button("Delete") { actions.delete(entry) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch entry.kind {
        case .image:
            if let image = store.thumbnail(for: entry) {
                let size = displaySize(for: image, maxWidth: 330, maxHeight: 120)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            } else {
                Label("Image", systemImage: "photo").font(.system(size: 12.5))
            }
        case .files:
            HStack(spacing: 9) {
                if let image = store.thumbnail(for: entry) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                } else {
                    Image(systemName: "doc").font(.system(size: 22))
                }
                Text(entry.displayText)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
        case .link:
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "link")
                Text(entry.displayText)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Color.accentColor)
        case .text, .richText, .other:
            Text(entry.displayText)
                .font(.system(size: 12.5))
                .lineLimit(4)
                .multilineTextAlignment(entry.isRightToLeft ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: entry.isRightToLeft ? .trailing : .leading)
        }
    }

    private var meta: some View {
        HStack(spacing: 5) {
            if let icon = AppIcons.icon(for: entry.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 13, height: 13)
            }
            Text(metaText).lineLimit(1)
            if entry.kind == .richText {
                Text("Formatted")
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            Spacer(minLength: 4)
            if entry.pinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(Color.accentColor)
                    .rotationEffect(.degrees(45))
            }
            if index < 9 {
                Text("⌘\(index + 1)").monospacedDigit()
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    private var hoverButtons: some View {
        HStack(spacing: 4) {
            RowButton(systemImage: entry.pinned ? "pin.slash" : "pin", help: entry.pinned ? "Unpin" : "Pin") {
                actions.togglePin(entry)
            }
            RowButton(systemImage: "trash", help: "Delete") {
                actions.delete(entry)
            }
        }
    }

    private var metaText: String {
        var parts: [String] = []
        if let source = entry.sourceName { parts.append(source) }
        if let detail = entry.detail, entry.kind != .files || !detail.hasPrefix("/") { parts.append(detail) }
        parts.append(Self.relativeFormatter.localizedString(for: entry.date, relativeTo: max(openedAt, entry.date)))
        return parts.joined(separator: " · ")
    }

    /// Thumbnails are stored at 2× resolution; show them at point size, never upscaled.
    private func displaySize(for image: NSImage, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        let width = max(image.size.width / 2, 1)
        let height = max(image.size.height / 2, 1)
        let scale = min(1, maxWidth / width, maxHeight / height)
        return CGSize(width: width * scale, height: height * scale)
    }
}

private struct RowButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .medium))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}
