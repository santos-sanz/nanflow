import Foundation

public enum TextStyle: String, CaseIterable, Sendable {
    case off
    case natural
    case informal
    case formal

    public var label: String {
        switch self {
        case .off: return "Apagado (sin IA)"
        case .natural: return "Natural"
        case .informal: return "Informal"
        case .formal: return "Formal"
        }
    }

    public var hint: String {
        switch self {
        case .off: return "Pega la transcripción cruda. Máxima velocidad, sin LLM."
        case .natural: return "Puntuación, tildes y limpieza de muletillas. Mismo registro que hablas."
        case .informal: return "Tono relajado y cercano, como para un mensaje a un colega."
        case .formal: return "Registro profesional, frases completas, sin coloquialismos."
        }
    }
}

public enum Formatter {
    public static let naturalSystemPrompt = """
    You are a speech-to-text post-processor, like Wispr Flow's text formatter.
    You receive a raw transcript of dictated speech and return the final polished text.

    RULES:
    - Respond ONLY with the polished text. No explanations, no quotes around it.
    - Keep the SAME LANGUAGE as the input (Spanish stays Spanish, English stays English). Never translate.
    - Add correct punctuation, capitalization and accents (tildes, e.g. "que" -> "qué" only when interrogative).
    - Remove filler words and hesitations: "eh", "em", "uh", "mhm", "este...", "o sea" (when pure filler), "like" (when filler), "pues" (when filler), "vale" (when filler), repeated false starts and stutters.
    - Keep commas as the speaker meant them; do not replace them with periods or semicolons.
    - Fix obvious speech-to-text misrecognitions of common words only if fully certain from context.
    - Keep the speaker's meaning and words as close to verbatim as possible. Do not summarize, do not rewrite style, do not add content.
    - Format lists when the speaker enumerates items.
    - Preserve technical terms, code identifiers, URLs, emails and numbers exactly as heard; use sensible casing for known products (e.g. macOS, iPhone, GitHub).
    - Dictation commands must pass through VERBATIM, without adding punctuation next to them: "nueva línea" (line break), "punto y aparte" (paragraph break), "dos puntos" (colon), "punto y coma" (semicolon). Do not remove, translate or rephrase them.
    - If the input is empty or only silence markers, return an empty string.
    - The text will be typed directly into whatever app the user is focused on (email, chat, editor): make it instantly paste-ready. No markdown unless the user dictated formatting.
    """

    public static let informalSystemPrompt = """
    You are a speech-to-text post-processor that rewrites dictated speech in a CASUAL, FRIENDLY tone.
    You receive a raw transcript of dictated speech and return the final relaxed text.

    RULES:
    - Respond ONLY with the rewritten text. No explanations, no quotes.
    - Keep the SAME LANGUAGE as the input. Never translate.
    - Casual tone, like texting a friend or a close teammate: light, direct, conversational.
    - Contractions and colloquial expressions welcome. Short sentences are fine.
    - Still add correct punctuation, capitalization and accents, and remove filler words ("eh", "em", "este...", "o sea", stutters).
    - Keep ALL the information the speaker said; do not summarize or omit content, and do not invent anything.
    - Never add emoji.
    - If the input is empty, return an empty string.
    """

    public static let formalSystemPrompt = """
    You are a speech-to-text post-processor that rewrites dictated speech in a PROFESSIONAL, FORMAL register.
    You receive a raw transcript of dictated speech and return the final formal text.

    RULES:
    - Respond ONLY with the rewritten text. No explanations, no quotes.
    - Keep the SAME LANGUAGE as the input. Never translate.
    - Professional register suitable for work emails, reports or client communication: complete sentences, precise vocabulary, no colloquialisms or slang.
    - Fix speech artifacts: remove fillers, repetitions, false starts and hesitations.
    - Keep ALL the information the speaker said; do not summarize or omit content, and do not invent anything.
    - Correct punctuation, capitalization and accents.
    - Greetings and closings only if the speaker actually said them.
    - If the input is empty, return an empty string.
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

    public static func systemPrompt(for style: TextStyle, dictionary: [String] = []) -> String {
        var base: String
        switch style {
        case .off, .natural: base = naturalSystemPrompt
        case .informal: base = informalSystemPrompt
        case .formal: base = formalSystemPrompt
        }
        let entries = dictionary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !entries.isEmpty {
            base += "\n\nSPELLING DICTIONARY — these names and terms MUST appear exactly as written here when they are heard:\n"
            base += entries.map { "- \($0)" }.joined(separator: "\n")
        }
        return base
    }

    /// Short natural dictations only need deterministic cleanup; skipping the LLM saves ~1 s.
    public static func shouldSkipLLM(_ raw: String, style: TextStyle, dictionary: [String] = [], wordLimit: Int = 3) -> Bool {
        guard style == .natural, dictionary.isEmpty else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !VoiceCommands.containsCommands(trimmed) else { return false }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        return words > 0 && words <= wordLimit
    }

    /// Deterministic fallback used for short text, style .off and when the LLM fails.
    public static func polishWithoutLLM(_ raw: String) -> String {
        var text = VoiceCommands.apply(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        text = text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        if let first = text.first, first.isLetter, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }
        if let last = text.last, last.isLetter || last.isNumber {
            text += "."
        }
        return text
    }

    /// Formats with graceful fallback: a failed/slow LLM never loses the dictation.
    public static func formatForDictation(
        _ raw: String,
        style: TextStyle,
        dictionary: [String],
        fastShort: Bool,
        using format: (String, TextStyle, [String]) async throws -> String
    ) async -> (text: String, usedFallback: Bool) {
        if style == .off {
            return (VoiceCommands.apply(raw), false)
        }
        if fastShort && shouldSkipLLM(raw, style: style, dictionary: dictionary) {
            return (polishWithoutLLM(raw), false)
        }
        do {
            return (VoiceCommands.apply(try await format(raw, style, dictionary)), false)
        } catch {
            return (polishWithoutLLM(raw), true)
        }
    }

    /// Formats raw transcript with the given style. Style .off should not call this (engine skips LLM).
    public static func formatDictation(_ raw: String, style: TextStyle = .natural, dictionary: [String] = []) async throws -> String {
        let client = ProviderSettings.shared.client()
        let formatted = try await client.chat(
            system: systemPrompt(for: style, dictionary: dictionary),
            user: raw,
            maxTokens: 2048,
            temperature: 0.1
        )
        let trimmed = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            return VoiceCommands.apply(String(trimmed.dropFirst().dropLast()))
        }
        return VoiceCommands.apply(trimmed)
    }

    public static func summarizeMeeting(_ transcript: String) async throws -> String {
        let client = ProviderSettings.shared.client()
        return try await client.chat(
            system: meetingSummarySystemPrompt,
            user: transcript,
            maxTokens: 2048,
            temperature: 0.3
        )
    }
}
