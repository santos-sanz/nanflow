import Foundation

/// Quick notes pad persisted to AppSupport/scratchpad.md; dictations can be appended to it.
public final class ScratchpadStore: @unchecked Sendable {
    public static let shared = ScratchpadStore()

    private let queue = DispatchQueue(label: "nanflow.scratchpad")
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        let dir = EnvLoader.appSupportDir()
        self.fileURL = fileURL ?? dir.appendingPathComponent("scratchpad.md")
    }

    public func read() -> String {
        queue.sync {
            (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }
    }

    public func write(_ text: String) {
        queue.sync {
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Appends a dated entry at the top, like a quick-capture journal.
    public func append(_ text: String, date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let stamp = df.string(from: date)
        queue.sync {
            let current = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let next = "## \(stamp)\n\n\(trimmed)\n\n\(current)"
            try? next.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    public var fileURLValue: URL { fileURL }
}
