import Foundation

/// Shapes clipboard text into a note. Deterministic and offline: no network,
/// no AI, no title-fetching. It only does things it can be sure about, so it
/// never mangles a grocery list into a code block.
///   - a lone URL stays as-is (already clickable in the editor)
///   - text that clearly reads as code or an error gets wrapped in a fence
///   - anything ambiguous is left exactly as pasted
public enum SmartCapture {
    public static func format(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        if isSingleURL(trimmed) { return trimmed }
        if looksLikeCodeOrError(trimmed), !trimmed.hasPrefix("```") {
            return "```\n\(trimmed)\n```"
        }
        return text
    }

    static func isSingleURL(_ s: String) -> Bool {
        guard !s.contains(where: \.isWhitespace) else { return false }
        return s.hasPrefix("http://") || s.hasPrefix("https://")
    }

    /// Conservative on purpose: needs a strong, unambiguous signal to fence.
    static func looksLikeCodeOrError(_ s: String) -> Bool {
        let lines = s.components(separatedBy: "\n")

        // Errors and stack traces are the highest-confidence signal.
        if s.contains("Traceback (most recent call last)") { return true }
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let range = t.range(of: #"^[A-Za-z.]*(Error|Exception):\s"#, options: .regularExpression),
               range.lowerBound == t.startIndex {
                return true
            }
        }

        // Code tokens that rarely show up in prose.
        let strongTokens = ["#include", "=> {", "() {", ");", "});", "const ",
                            "def ", "function ", "public static", "import java",
                            "std::", "println!", "console.log"]
        if strongTokens.contains(where: s.contains) { return true }

        guard lines.count >= 2 else { return false }

        // Balanced braces plus a semicolon or arrow: almost certainly code.
        if s.contains("{"), s.contains("}"), s.contains(";") || s.contains("=>") {
            return true
        }

        // Most non-empty lines are indented: a pasted code block.
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard nonEmpty.count >= 3 else { return false }
        let indented = nonEmpty.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }
        return Double(indented.count) / Double(nonEmpty.count) >= 0.6
    }
}
