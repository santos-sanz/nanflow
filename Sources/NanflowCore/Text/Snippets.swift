import Foundation

public struct Snippet: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var trigger: String
    public var expansion: String

    public init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        self.expansion = expansion
    }
}

/// Trigger phrase -> expansion, like Wispr Flow snippets. Persisted as JSON in AppSupport.
public final class SnippetsStore: @unchecked Sendable {
    public static let shared = SnippetsStore()

    private let queue = DispatchQueue(label: "nanflow.snippets")
    private let fileURL: URL
    private var items: [Snippet]

    public init(fileURL: URL? = nil) {
        let dir = EnvLoader.appSupportDir()
        self.fileURL = fileURL ?? dir.appendingPathComponent("snippets.json")
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([Snippet].self, from: data) {
            items = decoded
        } else {
            items = []
        }
    }

    public func all() -> [Snippet] {
        queue.sync { items }
    }

    public func set(_ newItems: [Snippet]) {
        queue.sync {
            items = newItems
            persist()
        }
    }

    public func add(trigger: String, expansion: String) {
        queue.sync {
            items.append(Snippet(trigger: trigger, expansion: expansion))
            persist()
        }
    }

    public func remove(id: UUID) {
        queue.sync {
            items.removeAll { $0.id == id }
            persist()
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func normalized(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[ \\t\n]+", with: " ", options: .regularExpression)
            .lowercased()
        // Whisper almost always appends a final period; dictation commands too.
        while let last = out.last, ",.;:!?".contains(last) {
            out = String(out.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// Whole-utterance match ("mi email" -> the expansion), used to skip the LLM entirely.
    public func exactMatch(_ text: String) -> String? {
        let target = Self.normalized(text)
        guard !target.isEmpty else { return nil }
        return queue.sync {
            items.first { Self.normalized($0.trigger) == target }?.expansion
        }
    }

    /// Whisper prompt conditioning with the triggers, so the ASR recognizes them
    /// (same idea as Wispr Flow biasing its vocabulary). Capped to stay small.
    public func promptHints() -> String? {
        let triggers = queue.sync {
            items.map { $0.trigger.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        guard !triggers.isEmpty else { return nil }
        var hints: [String] = []
        var total = 0
        for trigger in triggers {
            if total + trigger.count > 600 { break }
            hints.append(trigger)
            total += trigger.count + 1
        }
        guard !hints.isEmpty else { return nil }
        return hints.joined(separator: ". ") + "."
    }

    /// Replaces snippet triggers inside longer text, longest triggers first so
    /// "mi web personal" wins over "mi web". Case-insensitive with word boundaries.
    public func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let entries = queue.sync { items }
        var out = text
        for snippet in entries.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty else { continue }
            let pattern = "(?<![\\p{L}\\p{N}])(\(NSRegularExpression.escapedPattern(for: trigger)))(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: snippet.expansion)
        }
        return out
    }
}
