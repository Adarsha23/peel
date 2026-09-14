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
    }

    func noteAttachImageData(_ data: Data, at index: Int?) {
        guard let stored = store.attach(data: data, named: nextIndexedName(prefix: "image"),
                                        to: note.id) else { return }
        textView.insertPlain("⟦\(stored.lastPathComponent)⟧ ", at: index)
        reloadAttachments()
    }

    func noteHide() { hide() }

    /// Slash commands. Actions run async so the command line is erased first —
    /// archive/hide would otherwise persist the note with "/archive" still in it.
    func noteCommand(_ command: String) -> Bool {
        let run: () -> Void
        switch command {
        case "help", "?": run = { [weak self] in self?.app.showHelp() }
        case "new": run = { [weak self] in self?.app.newSticky() }
        case "search", "find": run = { [weak self] in self?.app.showSearch() }
        case "hide": run = { [weak self] in self?.hide() }
        case "behind", "park", "front", "float": run = { [weak self] in self?.toggleLayer() }
        case "archive", "done": run = { [weak self] in self?.archive() }
        case "shot", "screenshot": run = { [weak self] in self?.captureScreenshot() }
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
            guard Theme.palettes.contains(where: { $0.name == command }) else { return false }
            run = { [weak self] in self?.setColor(command) }
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
        if wasVisible { panel.orderOut(nil) } // don't photobomb your own screenshot
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", dest.path]
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if wasVisible { self.show(focus: false) }
                if FileManager.default.fileExists(atPath: dest.path) {
                    self.textView.insertPlain("⟦\(dest.lastPathComponent)⟧ ", at: nil)
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

        if modifiers == .command, key == "\r" {
            textView.toggleTodo(nil)
            return true
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
