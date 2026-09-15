import AppKit

/// Every in-sticky shortcut, remappable from config.json:
///   "keys": { "hide": "cmd+shift+w", "bold": "none", "newSticky": "cmd+t|ctrl+opt+n" }
/// Multiple chords per action split on "|"; "none" unbinds. Unknown actions are
/// ignored so a stale config never breaks launch.
struct KeyMap {
    enum Action: String, CaseIterable {
        case newSticky, hide, hideAll, toggleTodo, search, layerToggle, ghostToggle, lockToggle
        case screenshot, archive, bold, italic, code, strike, highlight
        case zoomIn, zoomOut, zoomReset
    }

    static let defaults: [Action: String] = [
        .newSticky: "cmd+t|ctrl+opt+n",
        .hide: "cmd+w",
        .hideAll: "cmd+esc",
        .toggleTodo: "cmd+return",
        .search: "ctrl+opt+f",
        .layerToggle: "ctrl+opt+b",
        .ghostToggle: "ctrl+opt+g",
        .lockToggle: "ctrl+opt+l",
        .screenshot: "ctrl+opt+s",
        .archive: "ctrl+opt+a",
        .bold: "cmd+b",
        .italic: "cmd+i",
        .code: "cmd+e",
        .strike: "cmd+shift+x",
        .highlight: "cmd+shift+h",
        .zoomIn: "cmd+=|cmd+shift+plus",
        .zoomOut: "cmd+-",
        .zoomReset: "cmd+0",
    ]

    private struct Chord: Equatable {
        let flags: NSEvent.ModifierFlags
        let key: String
    }

    private var chords: [(chord: Chord, action: Action)] = []

    init(overrides: [String: String]? = nil) {
        for action in Action.allCases {
            let spec = overrides?[action.rawValue] ?? KeyMap.defaults[action]!
            for part in spec.split(separator: "|") {
                if let chord = KeyMap.parse(String(part)) {
                    chords.append((chord, action))
                }
            }
        }
    }

    func action(for event: NSEvent) -> Action? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        let pressed = Chord(flags: flags, key: key)
        return chords.first { $0.chord == pressed }?.action
    }

    private static func parse(_ spec: String) -> Chord? {
        var flags: NSEvent.ModifierFlags = []
        var key: String?
        for token in spec.lowercased().split(separator: "+", omittingEmptySubsequences: true) {
            switch token {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt", "option", "alt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            case "return", "enter": key = "\r"
            case "esc", "escape": key = "\u{1B}"
            case "space": key = " "
            case "tab": key = "\t"
            case "delete", "backspace": key = "\u{7F}"
            case "plus": key = "+"
            case "none": return nil
            default: key = String(token)
            }
        }
        guard let key, !flags.isEmpty else { return nil }
        return Chord(flags: flags, key: key)
    }
}
