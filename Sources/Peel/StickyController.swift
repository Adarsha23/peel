import AppKit
import PeelKit

/// Owns one sticky: its panel, editor, header, attachments, and persistence.
final class StickyController: NSObject, NSWindowDelegate, NoteTextViewDelegate {
    private(set) var note: Note
    let panel: StickyPanel
    private(set) var lastDiskWrite = Date.distantPast

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
        textView.string = Markup.display(fromMarkdown: note.body, noteID: note.id)
        textView.restyle()
        reloadAttachments()
        if note.sunk { panel.level = .normal }
    }

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

    func show(focus: Bool) {
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
        let small = target.insetBy(dx: target.width * 0.02, dy: target.height * 0.02)
        panel.setFrame(small, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.13
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
        if focus { focusText() }
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
    }

    private func captureFrame() {
        if let full = expandedFrame {
            // Collapsed: persist the expanded geometry at the current position.
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
        if !panel.isKeyWindow, fresh.body != previous.body {
            textView.string = Markup.display(fromMarkdown: fresh.body, noteID: fresh.id)
            textView.restyle()
        }
        let diskFrame = NSRect(x: fresh.x, y: fresh.y, width: fresh.width, height: fresh.height)
        if diskFrame != panel.frame, fresh.x != 0 || fresh.y != 0 {
            panel.setFrame(diskFrame, display: true)
        }
        if fresh.open, !panel.isVisible { show(focus: false) }
        reloadAttachments()
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) { scheduleFrameSave() }
    func windowDidResize(_ notification: Notification) { scheduleFrameSave() }
    func windowDidResignKey(_ notification: Notification) { flushPendingSave() }

    private func scheduleFrameSave() {
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.captureFrame()
            self.persist(touch: false)
        }
    }

    // MARK: Attachments

    private static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]

    /// Images get an inline ⟦token⟧ where you dropped them; other files go to the strip.
    func noteAttachFiles(_ urls: [URL], at index: Int?) {
        var tokens: [String] = []
        for url in urls {
            guard let stored = store.attach(fileAt: url, to: note.id) else { continue }
            if Self.imageExtensions.contains(stored.pathExtension.lowercased()) {
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
                if Reminders.detect(in: "@remind \(args)") != nil { self.playChimePreview() }
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
        case "archive", "done": run = { [weak self] in self?.archive() }
        case "shot", "screenshot": run = { [weak self] in self?.captureScreenshot() }
        case "todo": run = { [weak self] in self?.textView.toggleTodo(nil) }
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
        for (label, date) in Self.remindOptions() {
            let item = NSMenuItem(title: "\(label)   \(Self.remindInsert(date))",
                                  action: #selector(remindOptionPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = date
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "or type your own:  @remind tomorrow 9am call bank",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        popup(menu, atCharacter: (anchor ?? textView.selectedRange()).location)
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
        guard let date = sender.representedObject as? Date else { return }
        let formatted = Self.remindInsert(date)
        panel.makeKey()
        panel.makeFirstResponder(textView)
        switch remindTarget {
        case .newLine:
            // Template with the message pre-selected — typing replaces it, so the
            // line itself shows where the reminder text goes.
            let prefix = "@remind \(formatted) - "
            let hint = "what to remember"
            let start = textView.selectedRange().location
            textView.insertPlain(prefix + hint, at: nil)
            textView.setSelectedRange(NSRange(location: start + (prefix as NSString).length,
                                              length: (hint as NSString).length))
        case .replaceDate(let range):
            textView.replaceRange(range, with: formatted)
            textView.setSelectedRange(NSRange(location: range.location + (formatted as NSString).length,
                                              length: 0))
        case .insertAfterToken(let token):
            textView.insertPlain(" \(formatted)", at: token.upperBound)
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

    /// The menu shows exactly the text that will be inserted, so the free-form
    /// format teaches itself.
    private static func remindOptions() -> [(String, Date)] {
        let calendar = Calendar.current
        let now = Date()
        func rounded(_ interval: TimeInterval) -> Date {
            let date = now.addingTimeInterval(interval)
            let step: TimeInterval = 300
            return Date(timeIntervalSinceReferenceDate:
                (date.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
        }
        var options: [(String, Date)] = [
            ("In 30 minutes", rounded(30 * 60)),
            ("In 1 hour", rounded(60 * 60)),
            ("In 3 hours", rounded(3 * 60 * 60)),
        ]
        if let tonight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now), tonight > now {
            options.append(("Tonight", tonight))
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        options.append(("Tomorrow morning", calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!))
        options.append(("Tomorrow evening", calendar.date(bySettingHour: 18, minute: 0, second: 0, of: tomorrow)!))
        if let monday = calendar.nextDate(after: now, matching: DateComponents(hour: 9, weekday: 2),
                                          matchingPolicy: .nextTime) {
            options.append(("Monday morning", monday))
        }
        return options
    }

    private static func remindInsert(_ date: Date) -> String {
        let calendar = Calendar.current
        let format = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
            ? "MMM d, h:mm a" : "MMM d yyyy, h:mm a"
        let f = DateFormatter()
        f.dateFormat = format
        return f.string(from: date)
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

    @objc private func colorPicked(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { setColor(name) }
    }

    @objc private func archivePicked() { archive() }

    @objc private func revealPicked() {
        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(for: note.id)])
    }

    // MARK: Key equivalents (the app is usually inactive, so the panel routes these)

    /// Sticky commands live on ⌃⌥ so they never collide with browser/terminal
    /// muscle memory (⌘N, ⌘W, ⌘F stay untouched). Only ⌘↩ is borrowed — the
    /// universal todo-toggle — and esc hides (handled via cancelOperation).
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()

        if modifiers == .command {
            switch key {
            case "\r": textView.toggleTodo(nil); return true
            case "t": app.newSticky(); return true          // browser muscle memory: new "tab"
            case "w": hide(); return true                   // …and close it
            case "\u{1B}": app.hideAll(); return true       // ⌘esc — clear the desk
            case "b": textView.toggleWrap("**"); return true
            case "i": textView.toggleWrap("*"); return true
            case "e": textView.toggleWrap("`"); return true
            default: break
            }
        }
        if modifiers == [.command, .shift] {
            switch key {
            case "x": textView.toggleWrap("~~"); return true
            case "h": textView.toggleWrap("=="); return true
            default: break
            }
        }
        guard modifiers == [.control, .option] else { return false }
        switch key {
        case "n": app.newSticky(); return true
        case "f": app.showSearch(); return true
        case "b": toggleLayer(); return true
        case "s": captureScreenshot(); return true
        case "a": archive(); return true
        default:
            if let digit = Int(key), (1...Theme.palettes.count).contains(digit) {
                setColor(Theme.palettes[digit - 1].name)
                return true
            }
            return false
        }
    }
}

// MARK: - Supporting views

/// The colored paper layer over the blur material.
final class TintView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Theme.cornerRadius
        layer?.borderWidth = 0.5
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = color.withAlphaComponent(0.88).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }
}

/// 26pt drag strip along the top; controls fade in on hover.
final class HeaderView: NSView {
    var onHide: (() -> Void)?
    var onNew: (() -> Void)?
    var onMenu: ((NSView) -> Void)?
    var onCollapse: (() -> Void)?
    var dotColor: NSColor = .controlAccentColor { didSet { dotButton.image = dotImage() } }

    private let hideButton = HeaderView.symbolButton("xmark", size: 9)
    private let newButton = HeaderView.symbolButton("plus", size: 10)
    private let dotButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        hideButton.target = self
        hideButton.action = #selector(hidePressed)
        hideButton.toolTip = "Hide (⌘W / esc)"
        newButton.target = self
        newButton.action = #selector(newPressed)
        newButton.toolTip = "New sticky (⌘N)"
        dotButton.isBordered = false
        dotButton.imagePosition = .imageOnly
        dotButton.image = dotImage()
        dotButton.target = self
        dotButton.action = #selector(menuPressed)
        dotButton.toolTip = "Color & actions"
        dotButton.translatesAutoresizingMaskIntoConstraints = false
        hideButton.translatesAutoresizingMaskIntoConstraints = false
        newButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hideButton)
        addSubview(newButton)
        addSubview(dotButton)
        NSLayoutConstraint.activate([
            hideButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            hideButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dotButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotButton.widthAnchor.constraint(equalToConstant: 14),
            dotButton.heightAnchor.constraint(equalToConstant: 14),
            newButton.trailingAnchor.constraint(equalTo: dotButton.leadingAnchor, constant: -8),
            newButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        hideButton.alphaValue = 0
        newButton.alphaValue = 0
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
    @objc private func menuPressed() { onMenu?(dotButton) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onCollapse?()
            return
        }
        window?.performDrag(with: event)
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
            dotButton.animator().alphaValue = hovering ? 1 : 0.5
        }
    }
}
