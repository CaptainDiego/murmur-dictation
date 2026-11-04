import Foundation

/// The last few transcripts, newest first, so a dictation that landed in
/// the wrong place can be fetched again from the menu.
///
/// Kept in memory only — never written to disk or UserDefaults — so quitting
/// Murmur (or choosing Clear) forgets everything that was said.
struct TranscriptHistory {
    /// The sizes offered in Settings.
    static let sizes = [5, 10, 25]

    /// Shrinking it drops the oldest transcripts straight away.
    var capacity: Int {
        didSet {
            capacity = max(1, capacity)
            trim()
        }
    }
    private(set) var items: [String] = []

    init(capacity: Int = 5) {
        self.capacity = max(1, capacity)
    }

    var isEmpty: Bool { items.isEmpty }

    mutating func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Saying the same thing twice shouldn't push something else out.
        items.removeAll { $0 == text }
        items.insert(text, at: 0)
        trim()
    }

    private mutating func trim() {
        if items.count > capacity {
            items.removeLast(items.count - capacity)
        }
    }

    mutating func clear() {
        items.removeAll()
    }

    /// A single-line menu title for a transcript.
    static func preview(_ text: String, limit: Int = 48) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
