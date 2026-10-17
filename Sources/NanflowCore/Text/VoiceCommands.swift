import Foundation

/// Deterministic dictation voice commands, applied after (or instead of) LLM formatting.
public enum VoiceCommands {
    /// Commands -> replacement. Spanish and English, matched case-insensitively with
    /// optional surrounding punctuation/space noise.
    public static let replacements: [(phrases: [String], replacement: String)] = [
        (["punto y aparte", "new paragraph"], "\n\n"),
        (["nueva línea", "nueva linea", "new line"], "\n"),
        (["punto y coma", "semicolon"], ";"),
        (["dos puntos", "colon"], ":"),
    ]

    /// Applies the commands to the text and cleans stray punctuation around the breaks.
    public static func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        for (phrases, replacement) in replacements {
            for phrase in phrases {
                out = replacePhrase(out, phrase: phrase, with: replacement)
            }
        }
        return cleanupBreaks(out)
    }

    /// Removes punctuation dangling at line starts and spaces around breaks
    /// (e.g. "Hola, \n." -> "Hola,\n" y "clave: \n\n, primero" -> "clave:\n\nprimero").
    static func cleanupBreaks(_ text: String) -> String {
        var out = text
        let range = NSRange(out.startIndex..., in: out)
        if let afterBreak = try? NSRegularExpression(pattern: "[\\n][ \\t]*[.,;:]+") {
            out = afterBreak.stringByReplacingMatches(in: out, range: range, withTemplate: "\n")
        }
        let range2 = NSRange(out.startIndex..., in: out)
        if let beforeBreak = try? NSRegularExpression(pattern: "[ \\t]+[\\n]") {
            out = beforeBreak.stringByReplacingMatches(in: out, range: range2, withTemplate: "\n")
        }
        let range3 = NSRange(out.startIndex..., in: out)
        if let afterBreakSpaces = try? NSRegularExpression(pattern: "[\\n][ \\t]+") {
            out = afterBreakSpaces.stringByReplacingMatches(in: out, range: range3, withTemplate: "\n")
        }
        return out
    }

    private static func replacePhrase(_ text: String, phrase: String, with replacement: String) -> String {
        // Permite "nueva línea", "Nueva Línea", "nueva línea," etc.
        let pattern = NSRegularExpression.escapedPattern(for: phrase)
        guard let regex = try? NSRegularExpression(pattern: "(?i)\(pattern)") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    /// True if the text contains at least one command phrase.
    public static func containsCommands(_ text: String) -> Bool {
        replacements.contains { entry in
            entry.phrases.contains { phrase in
                text.range(of: phrase, options: .caseInsensitive) != nil
            }
        }
    }
}
