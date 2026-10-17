import Foundation

public struct HistoryEntry: Codable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case dictation
        case meeting
    }

    public var id: UUID
    public var timestamp: Date
    public var kind: Kind
    public var app: String
    public var audioDuration: TimeInterval
    public var transcriptionMs: Int
    public var formattingMs: Int
    public var rawText: String
    public var finalText: String
    public var audioPath: String?
    public var summary: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: Kind,
        app: String = "",
        audioDuration: TimeInterval = 0,
        transcriptionMs: Int = 0,
        formattingMs: Int = 0,
        rawText: String = "",
        finalText: String = "",
        audioPath: String? = nil,
        summary: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.app = app
        self.audioDuration = audioDuration
        self.transcriptionMs = transcriptionMs
        self.formattingMs = formattingMs
        self.rawText = rawText
        self.finalText = finalText
        self.audioPath = audioPath
        self.summary = summary
    }
}

public final class HistoryStore: @unchecked Sendable {
    public static let shared = HistoryStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "nanflow.history")
    private var entries: [HistoryEntry] = []

    public init(fileURL: URL? = nil) {
        let dir = EnvLoader.appSupportDir()
        self.fileURL = fileURL ?? dir.appendingPathComponent("history.json")
        entries = (try? Self.read(fileURL: self.fileURL)) ?? []
    }

    public func add(_ entry: HistoryEntry) {
        queue.sync {
            entries.insert(entry, at: 0)
            if entries.count > 2000 { entries.removeLast(entries.count - 2000) }
            persist()
        }
    }

    public func update(_ entry: HistoryEntry) {
        queue.sync {
            if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[idx] = entry
                persist()
            }
        }
    }

    public func all() -> [HistoryEntry] {
        queue.sync { entries }
    }

    public func meetings() -> [HistoryEntry] {
        queue.sync { entries.filter { $0.kind == .meeting } }
    }

    public func dictations() -> [HistoryEntry] {
        queue.sync { entries.filter { $0.kind == .dictation } }
    }

    private func persist() {
        try? Self.write(entries, fileURL: fileURL)
    }

    static func read(fileURL: URL) throws -> [HistoryEntry] {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([HistoryEntry].self, from: data)
    }

    static func write(_ entries: [HistoryEntry], fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }
}
