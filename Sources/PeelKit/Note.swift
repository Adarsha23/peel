import Foundation

/// One sticky note: flat YAML-ish frontmatter + a Markdown body,
/// stored as a single human-readable .md file.
public struct Note: Equatable {
    public var id: String
    public var color: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var created: Date
    public var updated: Date
    /// Whether the sticky is currently shown on screen (survives restarts).
    public var open: Bool
    /// Parked behind normal windows (⌃⌥B) instead of floating above them.
    public var sunk: Bool
    /// Per-sticky text zoom (⌘+ / ⌘−).
    public var fontSize: Double
    public var body: String

    public static let defaultWidth = 340.0
    public static let defaultHeight = 280.0

    public init(id: String = Note.makeID(),
                color: String = "yellow",
                x: Double = 0, y: Double = 0,
                width: Double = Note.defaultWidth, height: Double = Note.defaultHeight,
                created: Date = Date(), updated: Date = Date(),
                open: Bool = true, sunk: Bool = false, fontSize: Double = 13,
                body: String = "") {
        self.id = id
        self.color = color
        self.x = x; self.y = y
        self.width = width; self.height = height
        self.created = created; self.updated = updated
        self.open = open
        self.sunk = sunk
        self.fontSize = fontSize
        self.body = body
    }

    /// IDs are sortable, readable, filesystem-safe: 20260914-142233-x9k2
    public static func makeID(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let alphabet = "abcdefghjkmnpqrstuvwxyz23456789"
        let suffix = String((0..<4).map { _ in alphabet.randomElement()! })
        return f.string(from: date) + "-" + suffix
    }

    /// First meaningful line of the body, stripped of list markers.
    public var title: String {
        for raw in body.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("![") { continue } // image refs make poor titles
            for prefix in ["- [x] ", "- [X] ", "- [ ] ", "- ", "* ", "## ", "# "] where line.hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count))
                break
            }
            if !line.isEmpty { return line }
        }
        return "Untitled"
    }

    public var todoCounts: (open: Int, done: Int) {
        var open = 0, done = 0
        for raw in body.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- [ ]") { open += 1 }
            else if line.hasPrefix("- [x]") || line.hasPrefix("- [X]") { done += 1 }
        }
        return (open, done)
    }
}

public extension Date {
    /// "now", "5m", "3h", "2d": how Peel talks about note age everywhere.
    var shortAge: String {
        let seconds = Int(-timeIntervalSinceNow)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}

// MARK: - Serialization

public extension Note {
    static let iso = ISO8601DateFormatter()

    /// Tolerant parser: a malformed file becomes a body-only note instead of an error.
    static func parse(fileContents: String, fallbackID: String) -> Note {
        var note = Note(id: fallbackID)
        let lines = fileContents.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else {
            note.body = fileContents
            return note
        }
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "id": if !value.isEmpty { note.id = value }
            case "color": note.color = value
            case "x": note.x = Double(value) ?? 0
            case "y": note.y = Double(value) ?? 0
            case "width": note.width = Double(value) ?? Note.defaultWidth
            case "height": note.height = Double(value) ?? Note.defaultHeight
            case "created": note.created = iso.date(from: value) ?? note.created
            case "updated": note.updated = iso.date(from: value) ?? note.updated
            case "open": note.open = (value == "true")
            case "sunk": note.sunk = (value == "true")
            case "fontSize": note.fontSize = Double(value) ?? 13
            default: break
            }
        }
        var bodyLines = Array(lines[(end + 1)...])
        if bodyLines.first == "" { bodyLines.removeFirst() }
        note.body = bodyLines.joined(separator: "\n")
        return note
    }

    func serialize() -> String {
        """
        ---
        id: \(id)
        color: \(color)
        x: \(Int(x.rounded()))
        y: \(Int(y.rounded()))
        width: \(Int(width.rounded()))
        height: \(Int(height.rounded()))
        created: \(Note.iso.string(from: created))
        updated: \(Note.iso.string(from: updated))
        open: \(open)
        sunk: \(sunk)
        fontSize: \(Int(fontSize.rounded()))
        ---

        \(body)
        """
    }
}
