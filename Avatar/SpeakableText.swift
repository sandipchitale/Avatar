import Foundation

/// What to say for a piece of Markdown: formatting isn't read, a link is its text, a heading or
/// list item is its words, a quote says "Quote:", and a fenced code block is announced by its
/// length rather than read.
///
/// Avatar speaks the Claude Code mod's reply this way, a sentence or two at a time, so a piece may
/// be part of a larger document; a fence it doesn't close is treated as code to its end.
/// Mood cues (`[happy]`) and emoji are left for `Script`.
nonisolated enum SpeakableText {
    static func from(markdown: String) -> String {
        var spoken: [String] = []
        var codeLines: Int?
        for rawLine in markdown.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if let lines = codeLines {
                    spoken.append("Code block, \(lines) line\(lines == 1 ? "" : "s").")
                    codeLines = nil
                } else {
                    codeLines = 0
                }
                continue
            }
            if codeLines != nil {
                codeLines! += 1
                continue
            }
            if let line = speakable(line: trimmed), !line.isEmpty { spoken.append(line) }
        }
        if let lines = codeLines, lines > 0 {
            spoken.append("Code block, \(lines) line\(lines == 1 ? "" : "s").")
        }
        return spoken.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// One line's words, or nil for a line that says nothing (a rule, a table's separator).
    private static func speakable(line: String) -> String? {
        var line = line
        // A horizontal rule, or a table's |---|---| separator.
        if line.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil { return nil }
        if line.range(of: #"^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$"#, options: .regularExpression) != nil { return nil }
        // Headings, list markers and quotes: their words, a number kept, a quote announced.
        line = line.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"^[-*+]\s+(\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"^(\d+)[.)]\s+"#, with: "$1. ", options: .regularExpression)
        if line.hasPrefix(">") {
            line = "Quote: " + line.replacingOccurrences(of: #"^(>\s?)+"#, with: "", options: .regularExpression)
        }
        // A table row: its cells, one after another.
        if line.hasPrefix("|") {
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: ", ")
        }
        // Images and links say their text; a bare address is just "a link".
        line = line.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        line = line.replacingOccurrences(of: #"<https?://[^>]+>"#, with: "a link", options: .regularExpression)
        line = line.replacingOccurrences(of: #"https?://\S+"#, with: "a link", options: .regularExpression)
        // HTML tags go; inline code keeps its text.
        line = line.replacingOccurrences(of: #"</?[A-Za-z][^>]*>"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"`+([^`]+)`+"#, with: "$1", options: .regularExpression)
        // Emphasis marks go, but not underscores inside words (snake_case) or a lone asterisk (2 * 3).
        line = line.replacingOccurrences(of: #"(\*\*|__)(\S(?:.*?\S)?)\1"#, with: "$2", options: .regularExpression)
        line = line.replacingOccurrences(of: #"~~(\S(?:.*?\S)?)~~"#, with: "$1", options: .regularExpression)
        line = line.replacingOccurrences(of: #"(?<![\w*])\*(\S(?:.*?\S)?)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        line = line.replacingOccurrences(of: #"(?<!\w)_(\S(?:.*?\S)?)_(?!\w)"#, with: "$1", options: .regularExpression)
        return line.trimmingCharacters(in: .whitespaces)
    }
}

/// Words as the speech bubble marks them and Play starts from them: runs of non-space, by UTF-16 range.
nonisolated enum Words {
    static func ranges(in text: String) -> [NSRange] {
        text.ranges(of: /\S+/).map { NSRange($0, in: text) }
    }

    /// The word holding `location`: the last one starting at or before it (the synthesizer's ranges
    /// don't always match whitespace-separated words exactly).
    static func containing(_ location: Int, in words: [NSRange]) -> NSRange? {
        words.last { $0.location <= location }
    }
}
