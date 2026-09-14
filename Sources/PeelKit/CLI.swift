import Foundation

/// Terminal interface. Operates directly on the note files, so it works whether
/// or not the app is running; the app's directory watcher picks up changes live.
public enum CLI {
    public static func run(_ args: [String], store: NoteStore = NoteStore()) -> Int32 {
        guard let command = args.first else { return help() }
        let rest = Array(args.dropFirst())
        switch command {
        case "list", "ls":      return list(store, includeArchived: rest.contains("--all"))
        case "show", "cat":     return show(store, idPrefix: rest.first)
        case "search", "find":  return search(store, query: rest.joined(separator: " "))
        case "new", "add":      return new(store, text: rest.joined(separator: " "))
        case "today":           return today(store)
        case "archive":         return archive(store, idPrefix: rest.first)
        case "path":            print(store.root.path); return 0
        case "ui":              return ui(rest.first)
        case "help", "-h", "--help": return help()
        default:
            fputs("peel: unknown command '\(command)'\n", stderr)
            _ = help()
            return 1
        }
    }

    private static func list(_ store: NoteStore, includeArchived: Bool) -> Int32 {
        let notes = store.loadAll(includeArchived: includeArchived)
        if notes.isEmpty { print("No notes yet. Try: peel new \"your first thought\""); return 0 }
        for note in notes {
            let todos = note.todoCounts
            let todoTag = todos.open + todos.done > 0 ? "  [\(todos.done)/\(todos.open + todos.done)]" : ""
            print("\(note.id)  \(relative(note.updated))\(todoTag)  \(note.title)")
        }
        return 0
    }

    private static func show(_ store: NoteStore, idPrefix: String?) -> Int32 {
        guard let prefix = idPrefix, let note = store.resolve(idPrefix: prefix) else {
            fputs("peel: note not found\n", stderr); return 1
        }
        print(note.serialize())
        let files = store.attachments(for: note.id)
        if !files.isEmpty {
            print("\nAttachments (\(store.attachmentsDir(for: note.id).path)):")
            for f in files { print("  \(f.lastPathComponent)") }
        }
        return 0
    }

    private static func search(_ store: NoteStore, query: String) -> Int32 {
        guard !query.isEmpty else { fputs("usage: peel search <query>\n", stderr); return 1 }
        let matches = store.search(query, in: store.loadAll(includeArchived: true))
        if matches.isEmpty { print("No matches."); return 0 }
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        for note in matches {
            print("\(note.id)  \(note.title)")
            for (i, line) in note.body.components(separatedBy: "\n").enumerated() {
                let lower = line.lowercased()
                if tokens.contains(where: { lower.contains($0) }) {
                    print("    \(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return 0
    }

    private static func new(_ store: NoteStore, text: String) -> Int32 {
        var body = text
        if body.isEmpty, isatty(fileno(stdin)) == 0 {
            body = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var note = Note(body: body) // x/y of 0 means "let the app place it"
        let url = store.save(&note)
        print(note.id)
        fputs("created \(url.path)\n", stderr)
        return 0
    }

    private static func today(_ store: NoteStore) -> Int32 {
        let notes = store.loadAll(includeArchived: true).filter { Calendar.current.isDateInToday($0.updated) }
        if notes.isEmpty { print("No notes touched today."); return 0 }
        for note in notes {
            print("## \(note.id) — \(note.title)\n")
            print(note.body)
            print("")
        }
        return 0
    }

    private static func archive(_ store: NoteStore, idPrefix: String?) -> Int32 {
        guard let prefix = idPrefix, let note = store.resolve(idPrefix: prefix) else {
            fputs("peel: note not found\n", stderr); return 1
        }
        store.archive(id: note.id)
        print("archived \(note.id)")
        return 0
    }

    /// Remote-controls the running app over a distributed notification.
    private static func ui(_ command: String?) -> Int32 {
        let known = ["toggle", "new", "search", "show-all", "hide-all"]
        guard let command, known.contains(command) else {
            fputs("usage: peel ui <\(known.joined(separator: "|"))>\n", stderr)
            return 1
        }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("io.barakel.peel.command"),
            object: command, userInfo: nil, deliverImmediately: true)
        return 0
    }

    private static func relative(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        switch s {
        case ..<60: return "now".padding(toLength: 7, withPad: " ", startingAt: 0)
        case ..<3600: return "\(s / 60)m ago".padding(toLength: 7, withPad: " ", startingAt: 0)
        case ..<86400: return "\(s / 3600)h ago".padding(toLength: 7, withPad: " ", startingAt: 0)
        default: return "\(s / 86400)d ago".padding(toLength: 7, withPad: " ", startingAt: 0)
        }
    }

    @discardableResult
    private static func help() -> Int32 {
        print("""
        peel — floating sticky notes, stored as plain markdown

        usage:
          peel                  launch / focus the app
          peel new [text]       create a note (reads stdin if piped)
          peel list [--all]     list notes (--all includes archived)
          peel show <id>        print a note + its attachments (id prefix ok)
          peel search <query>   full-text search across all notes
          peel today            print every note touched today (markdown)
          peel archive <id>     archive a note
          peel path             print the data directory
          peel ui <cmd>         control the running app: toggle|new|search|show-all|hide-all

        data lives in ~/Library/Application Support/Peel (override: PEEL_DATA_DIR)
        """)
        return 0
    }
}
