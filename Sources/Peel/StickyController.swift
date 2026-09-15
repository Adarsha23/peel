import AppKit
import PeelKit

/// Owns one sticky: its panel, editor, header, attachments, and persistence.
/// NSResponder so it can own the hover tracking area (instant un-ghost).
final class StickyController: NSResponder, NSWindowDelegate, NoteTextViewDelegate {
    private(set) var note: Note
    let panel: StickyPanel
    private(set) var lastDiskWrite = Date.distantPast
    private(set) var lastActivity = Date()
    private(set) var isGhosted = false
    private var isDocking = false
    private var preGhostFrame: NSRect?

    /// The header row is the floor: a ghosted sticky collapses to exactly this,
    /// and a fresh note opens at header + one line.
    private let headerHeight: CGFloat = 26
    private let minContentHeight: CGFloat = 34

    private unowned let app: AppDelegate
    private let textView = NoteTextView()
    private let strip = AttachmentStrip()
    private let tint = TintView()
    private let header: HeaderView
    private var saveTimer: Timer?
    private var frameTimer: Timer?

    var store: NoteStore { app.store }

    init(note: Note, app: AppDelegate) {
        self.note = note
        self.app = app
        self.header = HeaderView()
        let frame = NSRect(x: note.x, y: note.y, width: note.width, height: note.height)
        self.panel = StickyPanel(frame: frame)
        super.init()
        panel.sticky = self
        panel.delegate = self
        buildUI()
        placeOnScreenIfNeeded()
        applyPalette()
        textView.attachmentsDir = store.attachmentsDir(for: note.id)
        textView.baseFontSize = CGFloat(note.fontSize)
        textView.string = Markup.display(fromMarkdown: note.body, noteID: note.id)
        textView.restyle()
        reloadAttachments()
        header.locked = note.locked
        header.onLinks = { [weak self] in self?.showLinksMenu() }
        refreshBacklinks()
        autoFitHeight() // open minimally: fit the panel to its content
        if note.sunk { panel.level = .normal }
    }

    // MARK: Auto-height — the sticky is exactly as tall as its content

    /// Fit the panel height to the text (min one line) unless the user has
    /// dragged it to a size they want. Grows/shrinks from the top edge down.
    func autoFitHeight(animate: Bool = false) {
        guard !note.userSized, !isGhosted, expandedFrame == nil, !isDocking else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        guard let layout = textView.layoutManager, let container = textView.textContainer
        else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height + textView.textContainerInset.height * 2
        let body = max(minContentHeight, used + 6)
        let stripHeight: CGFloat = strip.isHidden ? 0 : 56
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let target = min(headerHeight + body + stripHeight, screen.visibleFrame.height * 0.7)
        guard abs(target - panel.frame.height) > 1 else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - target // top edge stays put
        frame.size.height = target
        if frame.minY < screen.visibleFrame.minY + 8 {
            frame.origin.y = screen.visibleFrame.minY + 8
        }
        panel.setFrame(frame, display: true, animate: animate)
        note.height = target
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI assembly

    private func buildUI() {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Theme.roundedMask(radius: Theme.cornerRadius)

        tint.translatesAutoresizingMaskIntoConstraints = false

        header.translatesAutoresizingMaskIntoConstraints = false
        header.onHide = { [weak self] in self?.hide() }
        header.onNew = { [weak self] in self?.app.newSticky() }
        header.onMenu = { [weak self] button in self?.showContextMenu(from: button) }
        header.onCollapse = { [weak self] in self?.toggleCollapse() }
        header.onGhost = { [weak self] in self?.toggleGhost() }
        header.onSnap = { [weak self] origin, size in
            guard let self else { return origin }
            return self.app.snappedOrigin(origin, size: size, excluding: self.note.id)
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .allowed

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.configure()
        textView.noteDelegate = self
        scroll.documentView = textView

        strip.onRemove = { [weak self] url in self?.removeAttachment(url) }

        effect.addSubview(tint)
        effect.addSubview(header)
        effect.addSubview(scroll)
        effect.addSubview(strip)
        effect.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        panel.contentView = effect

        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            tint.topAnchor.constraint(equalTo: effect.topAnchor),
            tint.bottomAnchor.constraint(equalTo: effect.bottomAnchor),

            header.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            header.topAnchor.constraint(equalTo: effect.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),

            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: strip.topAnchor),

            strip.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
    }

    private func placeOnScreenIfNeeded() {
        let frame = panel.frame
        let unplaced = note.x == 0 && note.y == 0
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        guard unplaced || !visible else { return }
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame
        let offset = CGFloat(app.cascadeIndex() % 6) * 26
        let origin = NSPoint(
            x: visibleFrame.midX - note.width / 2 + offset,
            y: visibleFrame.midY - note.height / 2 + visibleFrame.height * 0.12 - offset)
        panel.setFrameOrigin(origin)
        note.x = origin.x
        note.y = origin.y
        persist(touch: false)
    }

    private func applyPalette() {
        let palette = Theme.palette(note.color)
        tint.color = palette.background
        textView.accent = palette.accent
        header.dotColor = palette.accent
    }

    // MARK: Show / hide / archive

    /// `from` is a small source rect (a shelf tab) — the sticky expands out of
    /// it, dock-style; without it, the standard quick scale-in.
    func show(focus: Bool, from origin: NSRect? = nil) {
        touchActivity()
        isGhosted = false
        if !note.open {
            note.open = true
            persist(touch: false)
        }
        guard !panel.isVisible else {
            if focus { focusText() }
            return
        }
        if note.sunk {
            panel.level = .normal
            panel.alphaValue = 1
            panel.orderBack(nil) // restore parked notes without popping them on top
            if focus { focusText() }
            return
        }
        let target = panel.frame
        let start = origin ?? target.insetBy(dx: target.width * 0.02, dy: target.height * 0.02)
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = origin == nil ? 0.13 : 0.30
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
        if focus { focusText() }
    }

    // MARK: Idle life-cycle — solid → ghost → tucked into the shelf

    func touchActivity() {
        lastActivity = Date()
    }

    /// Any click on the panel: wake it up and bring it back solid.
    func stickyClicked() {
        touchActivity()
        setGhost(false)
    }

    /// Instant see-through on demand: the header eye, ⌃⌥G, or /ghost.
    func toggleGhost() {
        if isGhosted {
            touchActivity()
            setGhost(false)
        } else {
            setGhost(true, force: true)
        }
    }

    /// Ghost = translucent AND collapsed to just the header row, so an idle
    /// sticky is a thin bar you can read straight through. A click restores it.
    func setGhost(_ ghost: Bool, force: Bool = false) {
        guard ghost != isGhosted, panel.isVisible, !isDocking else { return }
        if ghost, note.locked { return } // pinned opaque never fades
        if ghost, panel.isKeyWindow, !force { return }
        if ghost, expandedFrame != nil { return } // already collapsed by hand
        isGhosted = ghost
        let target: NSRect
        if ghost {
            preGhostFrame = panel.frame
            var frame = panel.frame
            frame.origin.y = frame.maxY - headerHeight
            frame.size.height = headerHeight
            target = frame
        } else {
            target = preGhostFrame ?? panel.frame
            preGhostFrame = nil
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = ghost ? 0.5 : 1.0
            panel.animator().setFrame(target, display: true)
        }
    }

    /// ⌃⌥L, /lock, or the menu: pin the sticky opaque (never ghosts).
    func toggleLock() {
        note.locked.toggle()
        persist(touch: false)
        if note.locked, isGhosted { setGhost(false) }
        header.locked = note.locked
    }

    /// Minimize-to-shelf: shrink toward the bottom edge and fade, like the Dock.
    func dockToShelf() {
        guard !isDocking, panel.isVisible else { return }
        isDocking = true
        flushPendingSave()
        note.open = false
        persist(touch: false)
        let original = panel.frame
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let target = NSRect(x: original.midX - 80, y: screen.frame.minY - 8,
                            width: 160, height: 36)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.30
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.panel.animator().alphaValue = 0
            self.panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel.setFrame(original, display: false)
            self.panel.alphaValue = 1
            self.isGhosted = false
            self.isDocking = false
        })
    }

    override func mouseEntered(with event: NSEvent) {
        // hold solidity while reading; a ghosted sticky needs a click to return
        if !isGhosted { touchActivity() }
    }

    override func mouseExited(with event: NSEvent) {
        touchActivity() // idle countdown restarts from the moment you leave
    }

    /// Double-click the header — roll the sticky up to just its first line.
    private var expandedFrame: NSRect?
    var isCollapsed: Bool { expandedFrame != nil }

    func toggleCollapse() {
        if let full = expandedFrame {
            expandedFrame = nil
            var frame = panel.frame
            frame.origin.y = frame.maxY - full.height
            frame.size = full.size
            panel.setFrame(frame, display: true, animate: true)
        } else {
            expandedFrame = panel.frame
            var frame = panel.frame
            let collapsedHeight: CGFloat = 62
            frame.origin.y += frame.height - collapsedHeight
            frame.size.height = collapsedHeight
            panel.setFrame(frame, display: true, animate: true)
        }
    }

    /// ⌃⌥B — park the sticky behind normal windows / bring it back above them.
    func toggleLayer() {
        note.sunk ? floatUp() : sinkBehind()
    }

    func sinkBehind() {
        note.sunk = true
        persist(touch: false)
        panel.level = .normal
        panel.orderBack(nil)
    }

    func floatUp() {
        note.sunk = false
        persist(touch: false)
        panel.level = .floating
        panel.orderFrontRegardless()
    }

    func focusText() {
        if note.sunk { floatUp() } // summoning a parked sticky pulls it back up
        panel.makeKey()
        panel.makeFirstResponder(textView)
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.scrollRangeToVisible(NSRange(location: end, length: 0))
    }

    func hide() {
        flushPendingSave()
        note.open = false
        persist(touch: false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.09
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    func archive() {
        flushPendingSave()
        panel.orderOut(nil)
        store.archive(id: note.id)
        app.reminders.cancelAll(for: note.id)
        app.stickyWasArchived(id: note.id)
    }

    /// Panel is being closed because the note file vanished (deleted/archived externally).
    func closeForRemoval() {
        saveTimer?.invalidate()
        frameTimer?.invalidate()
        panel.orderOut(nil)
    }

    // MARK: Persistence

    func noteTextDidChange() {
        touchActivity()
        autoFitHeight(animate: true) // grow with the text as you type
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.saveBody()
        }
    }

    func flushPendingSave() {
        if saveTimer?.isValid == true || frameTimer?.isValid == true {
            saveTimer?.invalidate()
            frameTimer?.invalidate()
            captureFrame()
            saveBody()
        }
    }

    private func saveBody() {
        let markdown = Markup.markdown(fromDisplay: textView.string, noteID: note.id)
        guard markdown != note.body else { return }
        note.body = markdown
        persist(touch: true)
        app.reminders.sync(note: note)
        reloadAttachments() // deleting a ⟦token⟧ returns its file to the strip
        refreshBacklinks()
    }

    private func captureFrame() {
        // While ghosted or hand-collapsed the panel is a thin bar; persist the
        // real geometry (top edge fixed, so maxY is stable through the shrink).
        if let full = preGhostFrame ?? expandedFrame {
            note.x = panel.frame.origin.x
            note.y = panel.frame.maxY - full.height
            note.width = full.width
            note.height = full.height
            return
        }
        note.x = panel.frame.origin.x
        note.y = panel.frame.origin.y
        note.width = panel.frame.width
        note.height = panel.frame.height
    }

    private func persist(touch: Bool) {
        store.save(&note, touch: touch)
        lastDiskWrite = Date()
    }

    /// The note file changed on disk (CLI, Claude Code, another editor).
    func externalUpdate(_ fresh: Note) {
        guard Date().timeIntervalSince(lastDiskWrite) > 1.0 else { return }
        let previous = note
        note = fresh
        if fresh.color != previous.color { applyPalette() }
        if fresh.sunk != previous.sunk {
            fresh.sunk ? sinkBehind() : floatUp()
        }
        if fresh.locked != previous.locked {
            header.locked = fresh.locked
            if fresh.locked, isGhosted { setGhost(false) }
        }
        if !panel.isKeyWindow, fresh.body != previous.body {
            textView.string = Markup.display(fromMarkdown: fresh.body, noteID: fresh.id)
            textView.restyle()
            autoFitHeight(animate: true)
        }
        let diskFrame = NSRect(x: fresh.x, y: fresh.y, width: fresh.width, height: fresh.height)
        if fresh.userSized, diskFrame != panel.frame, fresh.x != 0 || fresh.y != 0 {
            panel.setFrame(diskFrame, display: true)
        }
        if fresh.open, !panel.isVisible { show(focus: false) }
        reloadAttachments()
        refreshBacklinks()
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        touchActivity()
        if panel.inLiveResize, !note.userSized {
            note.userSized = true // a hand-drag pins the size; stop auto-fitting
        }
        scheduleFrameSave()
    }

    func windowDidMove(_ notification: Notification) { touchActivity(); scheduleFrameSave() }

    func windowDidBecomeKey(_ notification: Notification) {
        touchActivity()
        setGhost(false)
    }

    func windowDidResignKey(_ notification: Notification) {
        touchActivity()
        flushPendingSave()
    }

    private func scheduleFrameSave() {
        guard !isDocking else { return } // the minimize animation isn't a resize
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.captureFrame()
            self.persist(touch: false)
        }
    }

    // MARK: Attachments

    /// Images get an inline ⟦token⟧ where you dropped them; other files go to the strip.
    func noteAttachFiles(_ urls: [URL], at index: Int?) {
        var tokens: [String] = []
        for url in urls {
            guard let stored = store.attach(fileAt: url, to: note.id) else { continue }
            if OCR.imageExtensions.contains(stored.pathExtension.lowercased()) {
                tokens.append("⟦\(stored.lastPathComponent)⟧")
            }
        }
        if !tokens.isEmpty {
            textView.insertPlain(tokens.joined(separator: " ") + " ", at: index)
        }
        reloadAttachments()
        focusAfterAttach()
    }

    func noteAttachImageData(_ data: Data, at index: Int?) {
        guard let stored = store.attach(data: data, named: nextIndexedName(prefix: "image"),
                                        to: note.id) else { return }
        textView.insertPlain("⟦\(stored.lastPathComponent)⟧ ", at: index)
        reloadAttachments()
        focusAfterAttach()
    }

    func appendClipboardText(_ text: String) {
        textView.insertPlain(text, at: nil)
        focusAfterAttach()
    }

    /// After a drop/paste/capture lands, keyboard focus belongs in the sticky
    /// with the caret right after what just arrived.
    private func focusAfterAttach() {
        panel.makeKey()
        panel.makeFirstResponder(textView)
    }

    func noteHide() { hide() }

    /// Slash commands. Actions run async so the command line is erased first —
    /// archive/hide would otherwise persist the note with "/archive" still in it.
    func noteCommand(_ raw: String) -> Bool {
        let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return false }
        let verb = first.lowercased()
        let args = parts.count > 1 ? String(parts[1]) : ""

        // "/remind in 20 min pay rent" → "@remind in 20 min pay rent " with live feedback.
        if verb == "remind" || verb == "reminder", !args.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.textView.insertPlain("@remind \(args) ", at: nil)
                if When.detect(in: args) != nil { self.playChimePreview() }
            }
            return true
        }
        guard args.isEmpty else { return false } // only /remind takes arguments

        let run: () -> Void
        switch verb {
        case "help", "?": run = { [weak self] in self?.app.showHelp() }
        case "new": run = { [weak self] in self?.app.newSticky() }
        case "search", "find": run = { [weak self] in self?.app.showSearch() }
        case "hide": run = { [weak self] in self?.hide() }
        case "behind", "park", "front", "float": run = { [weak self] in self?.toggleLayer() }
        case "ghost", "peek": run = { [weak self] in self?.toggleGhost() }
        case "lock", "pin", "unlock": run = { [weak self] in self?.toggleLock() }
        case "links", "related", "backlinks": run = { [weak self] in self?.showLinksMenu() }
        case "archive", "done": run = { [weak self] in self?.archive() }
        case "shot", "screenshot": run = { [weak self] in self?.captureScreenshot() }
        case "todo": run = { [weak self] in self?.textView.toggleTodo(nil) }
        case "count":
            run = { [weak self] in
                guard let self else { return }
                let text = self.textView.string
                let words = text.split { $0.isWhitespace || $0.isNewline }.count
                let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }.count
                let menu = NSMenu()
                let item = NSMenuItem(title: "\(words) words · \(text.count) characters · \(lines) lines",
                                      action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                self.popup(menu, atCharacter: self.textView.selectedRange().location)
            }
        case "lower":
            run = { [weak self] in self?.transformBody { $0.lowercased() } }
        case "upper":
            run = { [weak self] in self?.transformBody { $0.uppercased() } }
        case "trim":
            run = { [weak self] in
                self?.transformBody { text in
                    let trimmedLines = text.components(separatedBy: "\n")
                        .map { line in
                            var l = line
                            while l.hasSuffix(" ") || l.hasSuffix("\t") { l.removeLast() }
                            return l
                        }
                        .joined(separator: "\n")
                    return trimmedLines.replacingOccurrences(of: "\n\n\n+", with: "\n\n",
                                                             options: .regularExpression)
                }
            }
        case "code":
            run = { [weak self] in
                guard let self else { return }
                let start = self.textView.selectedRange().location
                self.textView.insertPlain("```\n\n```", at: nil)
                self.textView.setSelectedRange(NSRange(location: start + 4, length: 0))
            }
        case "remind", "reminder":
            run = { [weak self] in self?.showRemindPicker(target: .newLine) }
        case "date":
            run = { [weak self] in self?.textView.insertPlain(Self.slashDate.string(from: Date()), at: nil) }
        case "time":
            run = { [weak self] in self?.textView.insertPlain(Self.slashTime.string(from: Date()), at: nil) }
        case "copy":
            run = { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    Markup.markdown(fromDisplay: self.textView.string, noteID: self.note.id),
                    forType: .string)
            }
        case "open", "folder":
            run = { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.activateFileViewerSelecting([self.store.fileURL(for: self.note.id)])
            }
        default:
            guard Theme.palettes.contains(where: { $0.name == verb }) else { return false }
            run = { [weak self] in self?.setColor(verb) }
        }
        DispatchQueue.main.async(execute: run)
        return true
    }

    private func transformBody(_ transform: (String) -> String) {
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.replaceRange(full, with: transform(textView.string))
    }

    private static let slashDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd EEE"
        return f
    }()

    private static let slashTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: Reminder picker — choose a time instead of guessing the format

    private enum RemindTarget {
        case newLine                    // /remind: insert a whole @remind line at the caret
        case replaceDate(NSRange)       // clicked a token that already has a time
        case insertAfterToken(NSRange)  // clicked a token with no recognized time
    }

    private var remindTarget: RemindTarget = .newLine

    func noteRemindClicked(tokenRange: NSRange, dateRange: NSRange?) {
        if let dateRange {
            showRemindPicker(target: .replaceDate(dateRange), anchor: tokenRange)
        } else {
            showRemindPicker(target: .insertAfterToken(tokenRange), anchor: tokenRange)
        }
    }

    private func showRemindPicker(target: RemindTarget, anchor: NSRange? = nil) {
        remindTarget = target
        let menu = NSMenu()
        for phrase in Self.remindPhrases {
            if phrase.isEmpty {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: "\(phrase)   \(Self.preview(of: phrase))",
                                  action: #selector(remindOptionPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = phrase
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "or type your own: in 45 min · every friday 4pm · Sep 20 2:30pm",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        popup(menu, atCharacter: (anchor ?? textView.selectedRange()).location)
    }

    /// The menu inserts these exact phrases, so the free-text grammar teaches
    /// itself. Empty string = separator.
    private static let remindPhrases: [String] = [
        "in 5 min", "in 30 min", "in 2 hours",
        "", // one-shots above, absolutes below
        "tomorrow 9am", "tonight 8pm",
        "", // recurring
        "every day at 9am", "every weekday at 9:30am", "every weekend at 10am",
    ]

    private static func preview(of phrase: String) -> String {
        guard let match = When.detect(in: phrase) else { return "" }
        if let label = match.repeats.label { return "repeats \(label)" }
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return f.string(from: match.date)
    }

    private func popup(_ menu: NSMenu, atCharacter location: Int) {
        let range = NSRange(location: max(0, location), length: 1)
        let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        let windowPoint = panel.convertPoint(fromScreen: NSPoint(x: screenRect.minX, y: screenRect.minY))
        let viewPoint = textView.convert(windowPoint, from: nil)
        menu.popUp(positioning: nil, at: viewPoint, in: textView)
    }

    // MARK: Slash autocomplete — type "/" on an empty line, pick a command.
    // Type-to-filter works (NSMenu type-select); esc leaves the "/" for manual typing.

    private var pendingSlashLocation: Int?

    func noteSlashTyped(slashAt location: Int) {
        pendingSlashLocation = location
        DispatchQueue.main.async { [weak self] in self?.showSlashMenu(at: location) }
    }

    private func showSlashMenu(at location: Int) {
        let menu = NSMenu()
        func add(_ verb: String, _ hint: String, to target: NSMenu = menu) {
            let item = NSMenuItem(title: verb, action: #selector(slashPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = verb
            let title = NSMutableAttributedString(string: verb, attributes: [
                .font: NSFont.menuFont(ofSize: 13),
            ])
            title.append(NSAttributedString(string: "   \(hint)", attributes: [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            item.attributedTitle = title
            target.addItem(item)
        }
        add("remind", "notification at a time")
        add("todo", "make this line a todo")
        add("code", "code block")
        add("date", "insert today's date")
        add("time", "insert the time")
        menu.addItem(.separator())
        add("shot", "screenshot into the note")
        add("copy", "copy note as markdown")
        add("count", "words · characters · lines")
        add("lower", "lowercase the note")
        add("upper", "uppercase the note")
        add("trim", "strip trailing spaces, collapse blank runs")
        let colorItem = NSMenuItem(title: "color", action: nil, keyEquivalent: "")
        let colors = NSMenu()
        for palette in Theme.palettes {
            let item = NSMenuItem(title: palette.name, action: #selector(slashPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = palette.name
            item.image = Theme.swatch(palette)
            if palette.name == note.color { item.state = .on }
            colors.addItem(item)
        }
        colorItem.submenu = colors
        menu.addItem(colorItem)
        menu.addItem(.separator())
        add("new", "new sticky")
        add("search", "search notes")
        add(note.sunk ? "front" : "behind", note.sunk ? "bring forward" : "push behind windows")
        add("hide", "hide this sticky")
        add("archive", "archive this note")
        menu.addItem(.separator())
        add("open", "show note file in Finder")
        add("help", "shortcut cheatsheet")
        popup(menu, atCharacter: location)
    }

    @objc private func slashPicked(_ sender: NSMenuItem) {
        guard let verb = sender.representedObject as? String else { return }
        if let location = pendingSlashLocation {
            pendingSlashLocation = nil
            let ns = textView.string as NSString
            if location < ns.length, ns.character(at: location) == 0x2F {
                textView.replaceRange(NSRange(location: location, length: 1), with: "")
            }
        }
        _ = noteCommand(verb)
    }

    @objc private func remindOptionPicked(_ sender: NSMenuItem) {
        guard let phrase = sender.representedObject as? String else { return }
        panel.makeKey()
        panel.makeFirstResponder(textView)
        switch remindTarget {
        case .newLine:
            // Template with the message pre-selected — typing replaces it, so the
            // line itself shows where the reminder text goes.
            let prefix = "@remind \(phrase) - "
            let hint = "what to remember"
            let start = textView.selectedRange().location
            textView.insertPlain(prefix + hint, at: nil)
            textView.setSelectedRange(NSRange(location: start + (prefix as NSString).length,
                                              length: (hint as NSString).length))
        case .replaceDate(let range):
            textView.replaceRange(range, with: phrase)
            textView.setSelectedRange(NSRange(location: range.location + (phrase as NSString).length,
                                              length: 0))
        case .insertAfterToken(let token):
            textView.insertPlain(" \(phrase)", at: token.upperBound)
        }
        textView.scrollRangeToVisible(textView.selectedRange())
        playChimePreview()
    }

    /// Soft preview of the reminder chime — confirms scheduling audibly.
    private func playChimePreview() {
        guard let url = Bundle.main.url(forResource: "peel-chime", withExtension: "wav"),
              let sound = NSSound(contentsOf: url, byReference: true) else { return }
        sound.volume = 0.45
        sound.play()
    }

    private func nextIndexedName(prefix: String) -> String {
        let existing = Set(store.attachments(for: note.id).map(\.lastPathComponent))
        var n = 1
        while existing.contains("\(prefix)-\(n).png") { n += 1 }
        return "\(prefix)-\(n).png"
    }

    private func removeAttachment(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reloadAttachments()
    }

    /// The strip is the tray for attachments not referenced inline in the text.
    func reloadAttachments() {
        let body = textView.string
        let unreferenced = store.attachments(for: note.id)
            .filter { !body.contains("⟦\($0.lastPathComponent)⟧") }
        strip.set(urls: unreferenced)
    }

    func captureScreenshot() {
        let dest = store.attachmentsDir(for: note.id, create: true)
            .appendingPathComponent(nextIndexedName(prefix: "screenshot"))
        let wasVisible = panel.isVisible
        let caret = textView.selectedRange() // token goes back where you were typing
        if wasVisible { panel.orderOut(nil) } // don't photobomb your own screenshot
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", dest.path]
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if wasVisible { self.show(focus: false) }
                if FileManager.default.fileExists(atPath: dest.path) {
                    let length = (self.textView.string as NSString).length
                    self.textView.setSelectedRange(NSRange(location: min(caret.location, length), length: 0))
                    self.textView.insertPlain("⟦\(dest.lastPathComponent)⟧ ", at: nil)
                    self.focusAfterAttach()
                }
                self.reloadAttachments()
            }
        }
        try? process.run()
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    // MARK: Colors & menu

    func setColor(_ name: String) {
        note.color = name
        persist(touch: false)
        applyPalette()
    }

    /// ⌘+ / ⌘− / ⌘0 — per-sticky text zoom, persisted in the frontmatter.
    private func adjustFontSize(_ delta: Double = 0, reset: Bool = false) {
        note.fontSize = reset ? 13 : min(24, max(9, note.fontSize + delta))
        persist(touch: false)
        textView.baseFontSize = CGFloat(note.fontSize)
        autoFitHeight(animate: true)
    }

    // MARK: Backlinks / related notes

    /// A menu of notes this one links to and notes that link back to it.
    func showLinksMenu() {
        let (incoming, outgoing) = store.related(to: note)
        let menu = NSMenu()
        func section(_ title: String, _ notes: [Note]) {
            guard !notes.isEmpty else { return }
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for linked in notes {
                let item = NSMenuItem(title: "   " + linked.title,
                                      action: #selector(linkPicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = linked.id
                item.image = Theme.swatch(Theme.palette(linked.color), diameter: 9)
                menu.addItem(item)
            }
        }
        section("Links to", outgoing)
        if !incoming.isEmpty, !outgoing.isEmpty { menu.addItem(.separator()) }
        section("Linked from", incoming)
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "No links yet. Use [[note title]] to connect notes.",
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        popup(menu, atCharacter: textView.selectedRange().location)
    }

    @objc private func linkPicked(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { app.reveal(id: id, focus: true) }
    }

    /// Refresh the header's "linked from" count (cheap full-store scan).
    func refreshBacklinks() {
        header.backlinkCount = store.related(to: note).incoming.count
    }

    // MARK: Wiki links

    func noteWikiExists(_ title: String) -> Bool {
        app.findNote(titled: title) != nil
    }

    func noteOpenWiki(_ title: String) {
        if let id = app.findNote(titled: title) {
            app.reveal(id: id, focus: true)
        } else {
            app.newSticky(body: title + "\n") // Obsidian-style: the link births the note
        }
    }

    /// "[[": offer existing notes; picking one completes the link.
    func noteWikiTyped(at location: Int) {
        let titles = app.noteTitles().filter { $0.id != note.id }.prefix(15)
        guard !titles.isEmpty else { return }
        let menu = NSMenu()
        for entry in titles {
            let item = NSMenuItem(title: entry.title, action: #selector(wikiPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.title
            menu.addItem(item)
        }
        DispatchQueue.main.async { [weak self] in
            self?.popup(menu, atCharacter: max(0, location - 1))
        }
    }

    @objc private func wikiPicked(_ sender: NSMenuItem) {
        guard let title = sender.representedObject as? String else { return }
        textView.insertPlain("\(title)]] ", at: nil)
    }

    private func showContextMenu(from view: NSView) {
        let menu = NSMenu()
        for (index, palette) in Theme.palettes.enumerated() {
            let item = NSMenuItem(title: palette.title, action: #selector(colorPicked(_:)), keyEquivalent: "\(index + 1)")
            item.keyEquivalentModifierMask = [.control, .option]
            item.target = self
            item.image = Theme.swatch(palette)
            item.representedObject = palette.name
            if palette.name == note.color { item.state = .on }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let lockItem = NSMenuItem(title: note.locked ? "Unlock (allow fading)" : "Lock Opaque",
                                  action: #selector(lockPicked), keyEquivalent: "l")
        lockItem.keyEquivalentModifierMask = [.control, .option]
        lockItem.state = note.locked ? .on : .off
        lockItem.target = self
        menu.addItem(lockItem)
        let layerItem = NSMenuItem(title: note.sunk ? "Bring Forward" : "Push Behind Windows",
                                   action: #selector(layerPicked), keyEquivalent: "b")
        layerItem.keyEquivalentModifierMask = [.control, .option]
        layerItem.target = self
        menu.addItem(layerItem)
        let archiveItem = NSMenuItem(title: "Archive Note", action: #selector(archivePicked), keyEquivalent: "a")
        archiveItem.keyEquivalentModifierMask = [.control, .option]
        archiveItem.target = self
        menu.addItem(archiveItem)
        let folderItem = NSMenuItem(title: "Show in Finder", action: #selector(revealPicked), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    @objc private func layerPicked() { toggleLayer() }
    @objc private func lockPicked() { toggleLock() }

    @objc private func colorPicked(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { setColor(name) }
    }

    @objc private func archivePicked() { archive() }

    @objc private func revealPicked() {
        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(for: note.id)])
    }

    // MARK: Key equivalents (the app is usually inactive, so the panel routes these)

    /// All in-sticky shortcuts route through the user-remappable KeyMap.
    /// Color chords (⌃⌥1..7) stay fixed: one per palette, positional by design.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.control, .option],
           let digit = Int(event.charactersIgnoringModifiers ?? ""),
           (1...Theme.palettes.count).contains(digit) {
            setColor(Theme.palettes[digit - 1].name)
            return true
        }
        guard let action = app.keyMap.action(for: event) else { return false }
        switch action {
        case .newSticky: app.newSticky()
        case .hide: hide()
        case .hideAll: app.hideAll()
        case .toggleTodo: textView.toggleTodo(nil)
        case .search: app.showSearch()
        case .layerToggle: toggleLayer()
        case .ghostToggle: toggleGhost()
        case .lockToggle: toggleLock()
        case .screenshot: captureScreenshot()
        case .archive: archive()
        case .bold: textView.toggleWrap("**")
        case .italic: textView.toggleWrap("*")
        case .code: textView.toggleWrap("`")
        case .strike: textView.toggleWrap("~~")
        case .highlight: textView.toggleWrap("==")
        case .zoomIn: adjustFontSize(+1)
        case .zoomOut: adjustFontSize(-1)
        case .zoomReset: adjustFontSize(reset: true)
        }
        return true
    }
}

// MARK: - Supporting views

/// The colored paper layer over the blur material: stickies and reminder cards.
class TintView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }

    init(cornerRadius: CGFloat = Theme.cornerRadius) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = 0.5
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = color.withAlphaComponent(0.9).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
    }
}

/// 26pt drag strip along the top; controls fade in on hover.
final class HeaderView: NSView {
    var onHide: (() -> Void)?
    var onNew: (() -> Void)?
    var onMenu: ((NSView) -> Void)?
    var onCollapse: (() -> Void)?
    var onGhost: (() -> Void)?
    var onLinks: (() -> Void)?
    var onSnap: ((NSPoint, NSSize) -> NSPoint)?

    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var lastDragMouse: NSPoint?
    var dotColor: NSColor = .controlAccentColor { didSet { dotButton.image = dotImage() } }
    /// Pinned-opaque state: a small lock glyph stays visible even without hover.
    var locked = false {
        didSet {
            lockIndicator.isHidden = !locked
            ghostButton.isHidden = locked // ghosting is disabled while locked
        }
    }
    /// Count of notes linking here; shows a small clickable badge when > 0.
    var backlinkCount = 0 {
        didSet {
            linkButton.isHidden = backlinkCount == 0
            linkButton.title = " \(backlinkCount)"
        }
    }

    private let hideButton = HeaderView.symbolButton("xmark", size: 9)
    private let ghostButton = HeaderView.symbolButton("eye", size: 10)
    private let newButton = HeaderView.symbolButton("plus", size: 10)
    private let dotButton = NSButton()
    private let linkButton: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.font = Theme.rounded(10, weight: .semibold)
        button.contentTintColor = .tertiaryLabelColor
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        button.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Linked notes")?
            .withSymbolConfiguration(config)
        button.imageHugsTitle = true
        button.isHidden = true
        button.toolTip = "Linked notes (/links)"
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    private let lockIndicator: NSImageView = {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        let view = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")?
            .withSymbolConfiguration(config) ?? NSImage())
        view.contentTintColor = .tertiaryLabelColor
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        hideButton.target = self
        hideButton.action = #selector(hidePressed)
        hideButton.toolTip = "Hide (⌘W / esc)"
        ghostButton.target = self
        ghostButton.action = #selector(ghostPressed)
        ghostButton.toolTip = "See through (⌃⌥G), click the note to bring it back"
        newButton.target = self
        newButton.action = #selector(newPressed)
        newButton.toolTip = "New sticky (⌘T)"
        dotButton.isBordered = false
        dotButton.imagePosition = .imageOnly
        dotButton.image = dotImage()
        dotButton.target = self
        dotButton.action = #selector(menuPressed)
        dotButton.toolTip = "Color & actions"
        dotButton.translatesAutoresizingMaskIntoConstraints = false
        linkButton.target = self
        linkButton.action = #selector(linksPressed)
        hideButton.translatesAutoresizingMaskIntoConstraints = false
        newButton.translatesAutoresizingMaskIntoConstraints = false
        ghostButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hideButton)
        addSubview(newButton)
        addSubview(ghostButton)
        addSubview(dotButton)
        addSubview(lockIndicator)
        addSubview(linkButton)
        NSLayoutConstraint.activate([
            linkButton.leadingAnchor.constraint(equalTo: lockIndicator.trailingAnchor, constant: 8),
            linkButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            hideButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            hideButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            lockIndicator.leadingAnchor.constraint(equalTo: hideButton.trailingAnchor, constant: 8),
            lockIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dotButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotButton.widthAnchor.constraint(equalToConstant: 14),
            dotButton.heightAnchor.constraint(equalToConstant: 14),
            newButton.trailingAnchor.constraint(equalTo: dotButton.leadingAnchor, constant: -8),
            newButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ghostButton.trailingAnchor.constraint(equalTo: newButton.leadingAnchor, constant: -8),
            ghostButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        hideButton.alphaValue = 0
        newButton.alphaValue = 0
        ghostButton.alphaValue = 0
        dotButton.alphaValue = 0.5
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func symbolButton(_ name: String, size: CGFloat) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(config)
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    private func dotImage() -> NSImage {
        let color = dotColor
        return NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5)).fill()
            return true
        }
    }

    @objc private func hidePressed() { onHide?() }
    @objc private func newPressed() { onNew?() }
    @objc private func ghostPressed() { onGhost?() }
    @objc private func linksPressed() { onLinks?() }
    @objc private func menuPressed() { onMenu?(dotButton) }

    // Manual drag instead of performDrag so edges can magnetize to other
    // stickies and screen edges while moving.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onCollapse?()
            return
        }
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse = dragStartMouse,
              let startOrigin = dragStartOrigin,
              let window else { return }
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: startOrigin.x + (mouse.x - startMouse.x),
                             y: startOrigin.y + (mouse.y - startMouse.y))
        // Magnetize only while placing deliberately — snapping mid-flight
        // yanks the window around and reads as a bug, not a feature.
        let speed = lastDragMouse.map { hypot(mouse.x - $0.x, mouse.y - $0.y) } ?? 0
        lastDragMouse = mouse
        if speed < 6, let snapped = onSnap?(origin, window.frame.size) {
            origin = snapped
        }
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartMouse = nil
            dragStartOrigin = nil
            lastDragMouse = nil
        }
        guard dragStartMouse != nil, let window else { return }
        // Settle into alignment with a soft slide instead of a teleport.
        let snapped = onSnap?(window.frame.origin, window.frame.size) ?? window.frame.origin
        guard snapped != window.frame.origin else { return }
        var frame = window.frame
        frame.origin = snapped
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(frame, display: true)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ hovering: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            hideButton.animator().alphaValue = hovering ? 1 : 0
            newButton.animator().alphaValue = hovering ? 1 : 0
            ghostButton.animator().alphaValue = hovering ? 1 : 0
            dotButton.animator().alphaValue = hovering ? 1 : 0.5
        }
    }
}
