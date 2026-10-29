import Foundation

/// One remembered clipboard copy. The full pasteboard payload lives on disk
/// (see `HistoryStore`); this struct only holds what the UI needs.
struct ClipEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case text
        case richText
        case link
        case image
        case files
        case other
    }

    let id: UUID
    var kind: Kind
    /// Text shown in the list and used for search (truncated).
    var text: String
    /// Secondary detail, e.g. "1920 × 1080" for images or "3 files".
    var detail: String?
    var hasThumbnail: Bool
    var sourceBundleID: String?
    var sourceName: String?
    var date: Date
    var pinned: Bool
    var contentHash: String
    var byteCount: Int

    var displayText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return text.isEmpty ? "(empty)" : "(whitespace)" }
        return String(trimmed.prefix(600))
    }

    /// True when the first letter is Hebrew, Arabic or another right-to-left script.
    var isRightToLeft: Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                return true
            default:
                if CharacterSet.letters.contains(scalar) { return false }
            }
        }
        return false
    }
}

/// Raw pasteboard contents: one dictionary per pasteboard item, keyed by UTI.
typealias ClipPayload = [[String: Data]]
