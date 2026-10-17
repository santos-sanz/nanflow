import Foundation

public enum Formatter {
    public static let dictationSystemPrompt = """
    You are a speech-to-text post-processor, like Wispr Flow's text formatter.
    You receive a raw transcript of dictated speech and return the final polished text.

    RULES:
    - Respond ONLY with the polished text. No explanations, no quotes around it.
    - Keep the SAME LANGUAGE as the input (Spanish stays Spanish, English stays English). Never translate.
    - Add correct punctuation, capitalization and accents (tildes, e.g. "que" -> "qué" only when interrogative).
    - Remove filler words and hesitations: "eh", "em", "uh", "mhm", "este...", "o sea" (when pure filler), "like" (when filler), "pues" (when filler), "vale" (when filler), repeated false starts and stutters.
    - Fix obvious speech-to-text misrecognitions of common words only if fully certain from context.
    - Keep the speaker's meaning and words as close to verbatim as possible. Do not summarize, do not rewrite style, do not add content.
    - Format lists when the speaker enumerates items.
    - Preserve technical terms, code identifiers, URLs, emails and numbers exactly as heard; use sensible casing for known products (e.g. macOS, iPhone, GitHub).
    - If the input is empty or only silence markers, return an empty string.
    - The text will be typed directly into whatever app the user is focused on (email, chat, editor): make it instantly paste-ready. No markdown unless the user dictated formatting.
    """

    public static let meetingSummarySystemPrompt = """
    You are a meeting summarizer. You receive the timestamped transcript of a meeting (may mix languages, mainly Spanish and English).
    Respond with well-organized markdown IN THE DOMINANT LANGUAGE OF THE MEETING:
    ## Resumen / Summary
    3-5 bullet points of what was discussed.
    ## Decisiones / Decisions
    Explicit decisions made (or "No se tomaron decisiones explícitas").
    ## Acciones / Action items
    "- [owner] action" bullets with owners if identifiable, else just the action.
    Be factual, use only what is in the transcript. Do not invent names.
    """

    public static func formatDictation(_ raw: String) async throws -> String {
        let client = NanClient()
        let formatted = try await client.chat(
            system: dictationSystemPrompt,
            user: raw,
            maxTokens: 2048,
            temperature: 0.1
        )
        let trimmed = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    public static func summarizeMeeting(_ transcript: String) async throws -> String {
        let client = NanClient()
        return try await client.chat(
            system: meetingSummarySystemPrompt,
            user: transcript,
            maxTokens: 2048,
            temperature: 0.3
        )
    }
}
