import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

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
        case "links", "related": return links(store, idPrefix: rest.first)
        case "ui":              return ui(rest.first)
        case "doctor":          return doctor()
        case "help", "-h", "--help": return help()
        default:
            fputs("peel: unknown command '\(command)'\n", stderr)
            _ = help()
            return 1
        }
    }

    private static func list(_ store: NoteStore, includeArchived: Bool) -> Int32 {
        let notes = store.loadAll(includeArchived: includeArchived)
        if notes.isEmpty { print("nothing here yet. peel new \"first thought\" and we're rolling"); return 0 }
        for note in notes {
            let todos = note.todoCounts
            let todoTag = todos.open + todos.done > 0 ? "  [\(todos.done)/\(todos.open + todos.done)]" : ""
            let raw = note.updated.shortAge
            let age = (raw == "now" ? raw : raw + " ago").padding(toLength: 8, withPad: " ", startingAt: 0)
            print("\(note.id)  \(age)\(todoTag)  \(note.title)")
        }
        return 0
    }

    private static func show(_ store: NoteStore, idPrefix: String?) -> Int32 {
        guard let prefix = idPrefix, let note = store.resolve(idPrefix: prefix) else {
            fputs("peel: note not found\n", stderr); return 1
        }
        print(note.serialize())
        let related = store.related(to: note)
        if !related.outgoing.isEmpty {
            print("\nLinks to: " + related.outgoing.map(\.title).joined(separator: ", "))
        }
        if !related.incoming.isEmpty {
            print("Linked from: " + related.incoming.map(\.title).joined(separator: ", "))
        }
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
            print("## \(note.id) · \(note.title)\n")
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

    /// Why didn't my reminder fire? Reports the actual notification permission
    /// state and every pending reminder with its scheduled time.
    private static func doctor() -> Int32 {
        #if !canImport(UserNotifications)
        print("doctor checks macOS notification plumbing; on this platform your notes are just files, nothing to diagnose")
        return 0
        #else
        guard Bundle.main.bundlePath.hasSuffix(".app"), Bundle.main.bundleIdentifier != nil else {
            // Through the CLI symlink, Bundle.main sees /opt/homebrew/bin and the
            // notification daemon won't talk to us — re-exec the real binary.
            let exec = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            let resolved = exec.resolvingSymlinksInPath()
            if resolved != exec, resolved.path.contains(".app/Contents/MacOS/") {
                let process = Process()
                process.executableURL = resolved
                process.arguments = ["doctor"]
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus
                } catch {}
            }
            print("not running from Peel.app. notifications need the installed bundle: make install")
            return 1
        }
        let center = UNUserNotificationCenter.current()
        let semaphore = DispatchSemaphore(value: 0)

        var captured: UNNotificationSettings?
        center.getNotificationSettings { settings in
            captured = settings
            semaphore.signal()
        }
        semaphore.wait()
        let status = captured?.authorizationStatus ?? .notDetermined

        switch status {
        case .authorized, .provisional:
            print("notifications: allowed ✓")
        case .denied:
            print("notifications: DENIED. macOS is eating your reminders.")
            print("fix: System Settings → Notifications → Peel → Allow Notifications")
            print("     open \"x-apple.systempreferences:com.apple.preference.notifications\"")
        case .notDetermined:
            print("notifications: never answered. asking now, watch for the dialog")
            print("(it appears over the desktop, not over fullscreen apps)")
            var granted = false
            center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            print(granted ? "granted, reminders will fire now" : "not granted, reminders won't show")
        @unknown default:
            print("notifications: unknown status")
        }

        if let settings = captured, status == .authorized || status == .provisional {
            // "Allow" can be on while the visible parts are off — surface each piece.
            let style: String
            switch settings.alertStyle {
            case .banner: style = "banners ✓"
            case .alert: style = "alerts ✓"
            case .none: style = "NONE. invisible notifications, set Peel to Banners in System Settings"
            @unknown default: style = "?"
            }
            print("alert style: \(style)")
            if settings.alertSetting == .disabled {
                print("alerts: OFF. enable 'Show as banners' for Peel in System Settings")
            }
            if settings.soundSetting == .disabled {
                print("sound: off (chime won't play)")
            }
        }

        var pending: [UNNotificationRequest] = []
        center.getPendingNotificationRequests { requests in
            pending = requests
            semaphore.signal()
        }
        semaphore.wait()

        if pending.isEmpty {
            print("pending reminders: none. @remind lines schedule when their note saves while the app runs")
        } else {
            let f = DateFormatter()
            f.dateFormat = "EEE MMM d, h:mm a"
            print("pending reminders (\(pending.count)):")
            let dated = pending.map { req in
                (date: (req.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(),
                 body: req.content.body)
            }
            for item in dated.sorted(by: { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }) {
                print("  \(item.date.map(f.string(from:)) ?? "…")  \(item.body)")
            }
        }
        var delivered: [UNNotification] = []
        center.getDeliveredNotifications { notifications in
            delivered = notifications
            semaphore.signal()
        }
        semaphore.wait()
        if !delivered.isEmpty {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            print("recently delivered (in Notification Center):")
            for n in delivered.sorted(by: { $0.date > $1.date }).prefix(5) {
                print("  \(f.string(from: n.date))  \(n.request.content.body)")
            }
        }
        print("also check: a Focus / Do Not Disturb mode silences banners even when allowed.")
        return 0
        #endif
    }

    private static func links(_ store: NoteStore, idPrefix: String?) -> Int32 {
        guard let prefix = idPrefix, let note = store.resolve(idPrefix: prefix) else {
            fputs("peel: note not found\n", stderr); return 1
        }
        let related = store.related(to: note)
        if related.outgoing.isEmpty, related.incoming.isEmpty {
            print("no links. use [[note title]] to connect notes."); return 0
        }
        for linked in related.outgoing { print("→ \(linked.id)  \(linked.title)") }
        for linked in related.incoming { print("← \(linked.id)  \(linked.title)") }
        return 0
    }

    /// Remote-controls the running app over a distributed notification.
    private static func ui(_ command: String?) -> Int32 {
        let known = ["toggle", "new", "search", "show-all", "hide-all", "help", "clip", "shelf"]
        guard let command, known.contains(command) else {
            fputs("usage: peel ui <\(known.joined(separator: "|"))>\n", stderr)
            return 1
        }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("io.barakel.peel.command"),
            object: command, userInfo: nil, deliverImmediately: true)
        return 0
    }

    @discardableResult
    private static func help() -> Int32 {
        print("""
        peel: sticky notes that float over everything, stored as plain markdown

        usage:
          peel                  launch / focus the app
          peel new [text]       create a note (reads stdin if piped)
          peel list [--all]     list notes (--all includes archived)
          peel show <id>        print a note + its attachments (id prefix ok)
          peel search <query>   full-text search across all notes
          peel today            print every note touched today (markdown)
          peel archive <id>     archive a note
          peel links <id>       notes this one links to and from
          peel path             print the data directory
          peel ui <cmd>         control the running app: toggle|new|search|show-all|hide-all|help|clip

        data lives in ~/Library/Application Support/Peel (override: PEEL_DATA_DIR)
        """)
        return 0
    }
}
