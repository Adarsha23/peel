import AppKit
import PeelKit

/// Spotlight-style search: floating field, live results, ↑↓ + ↩ to jump to a note.
final class SearchController: NSObject, NSTextFieldDelegate, NSTableViewDataSource,
                              NSTableViewDelegate, NSWindowDelegate {
    private unowned let app: AppDelegate
    private var panel: SearchPanel?
    private let field = NSTextField()
    private let table = NSTableView()
    private var results: [Note] = []

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
        field.placeholderString = "Search notes…"
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        table.headerView = nil
        table.rowHeight = rowHeight
        table.backgroundColor = .clear
        table.style = .inset
        table.intercellSpacing = NSSize(width: 0, height: 2)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
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
        results = query.isEmpty ? Array(all.prefix(8)) : Array(app.store.search(query, in: all).prefix(10))
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        layout()
    }

    private func layout() {
        guard let panel else { return }
        let listHeight = results.isEmpty ? 0 : CGFloat(results.count) * (rowHeight + 2) + 12
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
        case #selector(NSResponder.moveDown(_:)):
            move(1); return true
        case #selector(NSResponder.moveUp(_:)):
            move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            openSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide(); return true
        default:
            return false
        }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let row = max(0, min(results.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func rowClicked() {
        openSelection()
    }

    private func openSelection() {
        let row = table.selectedRow >= 0 ? table.selectedRow : 0
        guard row < results.count else { return }
        let id = results[row].id
        hide()
        app.reveal(id: id, focus: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide() // Spotlight behavior: click elsewhere dismisses
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let note = results[row]
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

    private static func relative(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}

private final class SearchPanel: FloatPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
