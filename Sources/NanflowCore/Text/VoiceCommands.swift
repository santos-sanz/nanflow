import Foundation

/// Deterministic dictation voice commands, applied after (or instead of) LLM formatting.
public enum VoiceCommands {
    /// Commands -> replacement. Spanish and English, matched case-insensitively with
    /// optional surrounding punctuation/space noise. Applied longest-phrase-first.
    public static let replacements: [(phrases: [String], replacement: String)] = [
        (["punto y aparte", "new paragraph"], "\n\n"),
        (["nueva línea", "nueva linea", "new line"], "\n"),
        (["pulsa enter", "pulsa intro", "press enter"], "\n"),
        (["punto y coma", "semicolon"], ";"),
        (["dos puntos", "colon"], ":"),
        (["abrir paréntesis", "abrir parentesis", "open parenthesis"], "("),
        (["cerrar paréntesis", "cerrar parentesis", "close parenthesis"], ")"),
        (["comillas", "quote"], "\""),
        (["punto final", "full stop"], "."),
        (["coma", "comma"], ","),
    ]

    /// Applies the commands to the text and cleans stray punctuation around the breaks.
    public static func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = text

        var entries: [(pattern: String, replacement: String)] = []
        for (phrases, replacement) in replacements {
            for phrase in phrases {
                entries.append((NSRegularExpression.escapedPattern(for: phrase), replacement))
            }
        }
        // Longest phrases first so "punto y coma" wins over "coma".
        entries.sort { $0.pattern.count > $1.pattern.count }
        for entry in entries {
            guard let regex = try? NSRegularExpression(pattern: "(?i)\(entry.pattern)") else { continue }
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: entry.replacement)
        }
        return cleanupSpacing(cleanupBreaks(out))
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

    /// "uno , dos" -> "uno, dos", "Hola .  Mundo" -> "Hola. Mundo", "( x)" -> "(x)".
    static func cleanupSpacing(_ text: String) -> String {
        var out = text
        if let before = try? NSRegularExpression(pattern: "[ \\t]+([,.;:!?])") {
            out = before.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: "$1"
            )
        }
        if let afterOpen = try? NSRegularExpression(pattern: "\\([ \\t]+") {
            out = afterOpen.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: "("
            )
        }
        if let beforeClose = try? NSRegularExpression(pattern: "[ \\t]+\\)") {
            out = beforeClose.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: ")"
            )
        }
        if let double = try? NSRegularExpression(pattern: "[ \\t]{2,}") {
            out = double.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: " "
            )
        }
        return out
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
