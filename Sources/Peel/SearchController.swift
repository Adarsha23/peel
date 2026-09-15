import AppKit
import PeelKit

/// The command center: one field (`⌃⌥F`) that both finds notes and runs
/// actions. Type to filter notes, or lead with a verb (new, remind, today,
/// shot, show, hide, export) to run a command. ↑↓ to move, ↩ to run.
final class SearchController: NSObject, NSTextFieldDelegate, NSTableViewDataSource,
                              NSTableViewDelegate, NSWindowDelegate {
    private enum Row {
        case command(Command)
        case note(Note)
    }

    private struct Command {
        let symbol: String
        let label: String
        let hint: String
        let run: () -> Void
    }

    private unowned let app: AppDelegate
    private var panel: SearchPanel?
    private let field = NSTextField()
    private let table = NSTableView()
    private var rows: [Row] = []

    private let panelWidth: CGFloat = 560
    private let fieldHeight: CGFloat = 54
    private let rowHeight: CGFloat = 48

    init(app: AppDelegate) {
        self.app = app
        super.init()
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        buildIfNeeded()
        guard let panel else { return }
        field.stringValue = ""
        updateResults()
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: visible.midX - panelWidth / 2,
                                           y: visible.minY + visible.height * 0.72))
        layout()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(field)
        panel.animator().alphaValue = 1
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: Construction

    private func buildIfNeeded() {
        guard panel == nil else { return }
        let panel = SearchPanel(frame: NSRect(x: 0, y: 0, width: panelWidth, height: fieldHeight),
                                resizable: false)
        panel.onCancel = { [weak self] in self?.hide() }
        panel.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Theme.roundedMask(radius: 14)

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass",
                                              accessibilityDescription: "Search")!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))!)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.rounded(19)
        field.placeholderString = "Search notes, or type a command…"
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        table.headerView = nil
        table.rowHeight = rowHeight
        table.backgroundColor = .clear
        table.style = .inset
        table.intercellSpacing = NSSize(width: 0, height: 2)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(icon)
        effect.addSubview(field)
        effect.addSubview(scroll)
        panel.contentView = effect

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            icon.topAnchor.constraint(equalTo: effect.topAnchor, constant: 17),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: fieldHeight),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6),
        ])
        self.panel = panel
    }

    // MARK: Results

    private func updateResults() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        let all = app.store.loadAll()

        if query.isEmpty {
            rows = all.prefix(8).map(Row.note)
        } else {
            let commands = self.commands(for: query)
            if !commands.isEmpty {
                let rest = query.split(separator: " ", maxSplits: 1).count > 1
                    ? String(query.split(separator: " ", maxSplits: 1)[1]) : ""
                let matches = rest.isEmpty ? [] : app.store.search(rest, in: all).prefix(6)
                rows = commands.map(Row.command) + matches.map(Row.note)
            } else {
                var built = app.store.search(query, in: all).prefix(8).map(Row.note)
                built.append(.command(createCommand(query))) // type anything, Enter, it's a note
                rows = built
            }
        }
        table.reloadData()
        if !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        layout()
    }

    /// Verbs at the start of the query become runnable commands.
    private func commands(for query: String) -> [Command] {
        let parts = query.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts.first?.lowercased() ?? ""
        let rest = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "new", "note":
            return [Command(symbol: "plus", label: rest.isEmpty ? "New note" : "New note: \(rest)",
                            hint: "create") { [weak self] in self?.act { $0.newSticky(body: rest) } }]
        case "remind", "r":
            guard !rest.isEmpty, When.detect(in: "@remind \(rest)") != nil else { return [] }
            return [Command(symbol: "bell", label: "Remind: \(rest)", hint: "reminder") { [weak self] in
                self?.act { $0.newSticky(body: "@remind \(rest)") }
            }]
        case "today":
            return [Command(symbol: "calendar", label: "Today's notes", hint: "open") { [weak self] in
                self?.hide()
                let today = self?.app.store.loadAll().filter { Calendar.current.isDateInToday($0.updated) } ?? []
                for note in today { self?.app.reveal(id: note.id, focus: false) }
            }]
        case "shot", "screenshot", "capture":
            return [Command(symbol: "camera.viewfinder", label: "Screenshot into a note",
                            hint: "capture") { [weak self] in
                self?.hide(); self?.app.screenshotToSticky()
            }]
        case "show":
            return [Command(symbol: "square.stack", label: "Show all notes", hint: "") { [weak self] in
                self?.hide(); self?.app.showAll()
            }]
        case "hide":
            return [Command(symbol: "eye.slash", label: "Hide all notes", hint: "") { [weak self] in
                self?.hide(); self?.app.hideAll()
            }]
        case "export", "backup":
            return [Command(symbol: "arrow.down.doc", label: "Export a backup zip", hint: "") { [weak self] in
                self?.hide(); self?.app.exportBackup()
            }]
        default:
            return []
        }
    }

    private func createCommand(_ text: String) -> Command {
        Command(symbol: "plus", label: "New note: \(text)", hint: "create") { [weak self] in
            self?.act { $0.newSticky(body: text) }
        }
    }

    private func act(_ body: @escaping (AppDelegate) -> Void) {
        hide()
        body(app)
    }

    private func layout() {
        guard let panel else { return }
        let listHeight = rows.isEmpty ? 0 : CGFloat(rows.count) * (rowHeight + 2) + 12
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = fieldHeight + listHeight
        frame.size.width = panelWidth
        frame.origin.y = top - frame.size.height
        panel.setFrame(frame, display: true)
    }

    func controlTextDidChange(_ obj: Notification) {
        updateResults()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): runSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)): hide(); return true
        default: return false
        }
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let row = max(0, min(rows.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func rowClicked() { runSelection() }

    private func runSelection() {
        let index = table.selectedRow >= 0 ? table.selectedRow : 0
        guard index < rows.count else { return }
        switch rows[index] {
        case .command(let command):
            command.run()
        case .note(let note):
            hide()
            app.reveal(id: note.id, focus: true)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide() // Spotlight behavior: click elsewhere dismisses
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .command(let command): return commandCell(command)
        case .note(let note): return noteCell(note)
        }
    }

    private func commandCell(_ command: Command) -> NSView {
        let cell = NSView()
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let icon = NSImageView(image: NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        let label = NSTextField(labelWithString: command.label)
        label.font = Theme.rounded(13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        let hint = NSTextField(labelWithString: command.hint)
        hint.font = Theme.rounded(11)
        hint.textColor = .tertiaryLabelColor

        for view in [icon, label, hint] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: hint.leadingAnchor, constant: -10),
            hint.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
            hint.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func noteCell(_ note: Note) -> NSView {
        let palette = Theme.palette(note.color)
        let cell = NSView()
        let dot = NSImageView(image: Theme.swatch(palette, diameter: 10))
        let title = NSTextField(labelWithString: note.title)
        title.font = Theme.rounded(13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let snippet = NSTextField(labelWithString: snippetLine(for: note))
        snippet.font = Theme.rounded(11)
        snippet.textColor = .secondaryLabelColor
        snippet.lineBreakMode = .byTruncatingTail
        let date = NSTextField(labelWithString: note.updated.shortAge)
        date.font = Theme.rounded(11)
        date.textColor = .tertiaryLabelColor

        for view in [dot, title, snippet, date] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 7),
            title.trailingAnchor.constraint(lessThanOrEqualTo: date.leadingAnchor, constant: -10),
            snippet.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            snippet.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            snippet.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -14),
            date.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
            date.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
        return cell
    }

    private func snippetLine(for note: Note) -> String {
        let tokens = field.stringValue.lowercased().split(separator: " ").map(String.init)
        let lines = Markup.display(fromMarkdown: note.body, noteID: note.id).components(separatedBy: "\n")
        if let token = tokens.first {
            for line in lines where line.lowercased().contains(token) {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return lines.dropFirst().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}

private final class SearchPanel: FloatPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
