import Foundation

/// Maps between the Markdown stored on disk and the glyphs shown in the editor.
/// On disk (Claude-friendly):   - [ ] task   /  - [x] task   /  - bullet
/// In the editor (human-friendly):  ☐ task  /  ☑ task  /  • bullet
public enum Markup {
    public static let todoGlyph: Character = "☐"
    public static let doneGlyph: Character = "☑"
    public static let bulletGlyph: Character = "•"

    /// Inline image references. On disk: standard markdown, resolvable by any tool:
    ///   ![image-1.png](../attachments/<noteID>/image-1.png)
    /// In the editor: a compact clickable token sitting right where you dropped it:
    ///   ⟦image-1.png⟧
    /// The path is derived from noteID + filename, so the mapping is lossless.
    public static let tokenPattern = "⟦([^⟧\\n]+)⟧"

    public static func display(fromMarkdown text: String, noteID: String? = nil) -> String {
        var result = mapLines(text) { indent, rest in
            if rest.hasPrefix("- [x] ") || rest.hasPrefix("- [X] ") { return indent + "☑ " + String(rest.dropFirst(6)) }
            if rest.hasPrefix("- [ ] ") { return indent + "☐ " + String(rest.dropFirst(6)) }
            if rest == "- [x]" || rest == "- [X]" { return indent + "☑ " }
            if rest == "- [ ]" { return indent + "☐ " }
            if rest.hasPrefix("- ") { return indent + "• " + String(rest.dropFirst(2)) }
            if rest.hasPrefix("* ") { return indent + "• " + String(rest.dropFirst(2)) }
            return indent + rest
        }
        if let noteID {
            let escaped = NSRegularExpression.escapedPattern(for: noteID)
            result = replacing(result,
                               pattern: "!\\[[^\\]\\n]*\\]\\(\\.\\./attachments/\(escaped)/([^)\\n]+)\\)",
                               template: "⟦$1⟧")
        }
        return result
    }

    public static func markdown(fromDisplay text: String, noteID: String? = nil) -> String {
        var input = text
        if let noteID {
            input = replacing(input, pattern: tokenPattern,
                              template: "![$1](../attachments/\(noteID)/$1)")
        }
        return mapLines(input) { indent, rest in
            if rest.hasPrefix("☑ ") { return indent + "- [x] " + String(rest.dropFirst(2)) }
            if rest.hasPrefix("☐ ") { return indent + "- [ ] " + String(rest.dropFirst(2)) }
            if rest == "☑" { return indent + "- [x] " }
            if rest == "☐" { return indent + "- [ ] " }
            if rest.hasPrefix("• ") { return indent + "- " + String(rest.dropFirst(2)) }
            if rest == "•" { return indent + "- " }
            return indent + rest
        }
    }

    private static func replacing(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: template)
    }

    /// Applies a per-line transform, leaving code-fence contents untouched.
    private static func mapLines(_ text: String, _ transform: (String, String) -> String) -> String {
        var inFence = false
        return text.components(separatedBy: "\n").map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                return line
            }
            if inFence { return line }
            let indentEnd = line.firstIndex { $0 != " " && $0 != "\t" } ?? line.endIndex
            return transform(String(line[..<indentEnd]), String(line[indentEnd...]))
        }.joined(separator: "\n")
    }
}
