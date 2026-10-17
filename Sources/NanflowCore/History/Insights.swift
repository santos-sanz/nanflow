import Foundation

public struct InsightsSummary: Equatable, Sendable {
    public let dictationCount: Int
    public let totalWords: Int
    public let averageWPM: Int
    public let totalMinutes: Int
}

/// Usage stats computed locally from the history, like Wispr Flow's Insights (lite).
public enum Insights {
    public static func summary(_ entries: [HistoryEntry]) -> InsightsSummary {
        let dictations = entries.filter { $0.kind == .dictation && !$0.finalText.isEmpty }
        let totalWords = dictations.reduce(0) { $0 + wordCount($1.finalText) }
        let totalSeconds = dictations.reduce(0.0) { $0 + max($1.audioDuration, 0) }
        let wpm = totalSeconds > 1 ? Double(totalWords) / (totalSeconds / 60) : 0
        return InsightsSummary(
            dictationCount: dictations.count,
            totalWords: totalWords,
            averageWPM: Int(wpm.rounded()),
            totalMinutes: Int(totalSeconds / 60)
        )
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
