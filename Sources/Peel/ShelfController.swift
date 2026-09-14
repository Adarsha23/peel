import AppKit
import PeelKit

/// The shelf: push the cursor to the bottom screen edge and every note rises as
/// a small tab (first line = label, newest first). Click one to open it.
/// Uses a cheap mouse-position poll — no event taps, no permissions.
final class ShelfController {
    private unowned let app: AppDelegate
    private var panel: FloatPanel?
    private var pollTimer: Timer?
    private var shown = false
    private var holdUntil = Date.distantPast // manual (peel ui shelf) shows linger
    private let shelfHeight: CGFloat = 40

    init(app: AppDelegate) {
        self.app = app
    }

    func start() {
        // ponytail: 0.15s NSEvent.mouseLocation poll beats a CGEventTap that
        // would drag in the Accessibility permission
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
        else { return }
        let bottom = screen.frame.minY
        // leave the corners alone — hot corners live there
        let inCorner = mouse.x < screen.frame.minX + 80 || mouse.x > screen.frame.maxX - 80
        if !shown, mouse.y <= bottom + 1.5, !inCorner {
            show(on: screen)
        } else if shown, mouse.y > bottom + shelfHeight + 60, Date() > holdUntil {
            hide()
        }
    }

    func showManually(on screen: NSScreen) {
        holdUntil = Date().addingTimeInterval(3)
        show(on: screen)
    }

    private var currentScreen: NSScreen?

    func show(on screen: NSScreen) {
        guard buildContent() != nil else { return }
        guard let panel else { return }
        currentScreen = screen
        layout(panel: panel, on: screen, animateIn: true)
    }

    /// Rebuild tabs in place (a sticky was closed from the shelf) — no re-animation.
    private func refresh() {
        guard shown, let screen = currentScreen, buildContent() != nil, let panel else {
            hide()
            return
        }
        layout(panel: panel, on: screen, animateIn: false)
    }

    /// Returns nil when there are no notes to show.
    private func buildContent() -> NSView? {
        let notes = app.store.loadAll()
        guard !notes.isEmpty else { return nil }
        let panel = self.panel ?? FloatPanel(frame: .zero, resizable: false)
        self.panel = panel

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 0, right: 8)
        var anyVisible = false
        for note in notes.prefix(12) {
            let isVisible = app.controllers[note.id]?.panel.isVisible == true
            anyVisible = anyVisible || isVisible
            let tab = ShelfTab(note: note, dimmed: isVisible, closable: isVisible,
                               onOpen: { [weak self] id, tabRect in
                                   self?.hide()
                                   self?.app.reveal(id: id, focus: true, from: tabRect)
                               },
                               onClose: { [weak self] id in
                                   self?.app.controllers[id]?.hide()
                                   self?.refresh()
                               })
            stack.addArrangedSubview(tab)
        }
        if anyVisible {
            stack.addArrangedSubview(CloseAllTab { [weak self] in
                self?.app.hideAll()
                self?.refresh()
            })
        }
        let container = NSView()
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        return container
    }

    private func layout(panel: FloatPanel, on screen: NSScreen, animateIn: Bool) {
        guard let stack = panel.contentView?.subviews.first else { return }
        let width = min(stack.fittingSize.width, screen.frame.width - 40)
        let target = NSRect(x: screen.frame.midX - width / 2,
                            y: screen.frame.minY,
                            width: width, height: shelfHeight)
        if !animateIn {
            panel.setFrame(target, display: true)
            return
        }
        var start = target
        start.origin.y -= shelfHeight
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        shown = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
    }

    func hide() {
        guard shown, let panel else { return }
        shown = false
        var target = panel.frame
        target.origin.y -= shelfHeight
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
            panel?.alphaValue = 1
        })
    }
}

/// One tab on the shelf: the note's paper color, its accent dot, its first line.
/// Visible stickies are closable browser-style — hovering swaps the dot for ×.
private final class ShelfTab: NSView {
    private let noteID: String
    private let onOpen: (String, NSRect?) -> Void
    private let onClose: (String) -> Void
    private let background: NSColor
    private let closable: Bool
    private let dot: NSImageView
    private let closeButton = NSButton()

    init(note: Note, dimmed: Bool, closable: Bool,
         onOpen: @escaping (String, NSRect?) -> Void,
         onClose: @escaping (String) -> Void) {
        self.noteID = note.id
        self.onOpen = onOpen
        self.onClose = onClose
        self.closable = closable
        let palette = Theme.palette(note.color)
        self.background = palette.background
        self.dot = NSImageView(image: Theme.swatch(palette, diameter: 10))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] // top corners only
        alphaValue = dimmed ? 0.55 : 1.0
        toolTip = note.title

        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(config)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.toolTip = "Close sticky"
        closeButton.isHidden = true

        let label = NSTextField(labelWithString: note.title)
        label.font = Theme.rounded(12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        for view in [dot, closeButton, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = background.withAlphaComponent(0.97).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard closable else { return }
        dot.isHidden = true
        closeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        dot.isHidden = false
        closeButton.isHidden = true
    }

    @objc private func closePressed() {
        onClose(noteID)
    }

    override func mouseDown(with event: NSEvent) {
        // the sticky expands out of this tab, Dock-style
        let screenRect = window.map { $0.convertToScreen(convert(bounds, to: nil)) }
        onOpen(noteID, screenRect)
    }
}

/// The trailing "close every visible sticky" control.
private final class CloseAllTab: NSView {
    private let onCloseAll: () -> Void

    init(onCloseAll: @escaping () -> Void) {
        self.onCloseAll = onCloseAll
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        toolTip = "Close all stickies (⌘esc)"

        let label = NSTextField(labelWithString: "✕ all")
        label.font = Theme.rounded(12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onCloseAll()
    }
}
