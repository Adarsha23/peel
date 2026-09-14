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

    func show(on screen: NSScreen) {
        let notes = app.store.loadAll()
        guard !notes.isEmpty else { return }
        let panel = self.panel ?? FloatPanel(frame: .zero, resizable: false)
        self.panel = panel

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 0, right: 8)
        for note in notes.prefix(12) {
            let alreadyVisible = app.controllers[note.id]?.panel.isVisible == true
            stack.addArrangedSubview(ShelfTab(note: note, dimmed: alreadyVisible) { [weak self] id, tabRect in
                self?.hide()
                self?.app.reveal(id: id, focus: true, from: tabRect)
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

        let width = min(stack.fittingSize.width, screen.frame.width - 40)
        let start = NSRect(x: screen.frame.midX - width / 2,
                           y: screen.frame.minY - shelfHeight,
                           width: width, height: shelfHeight)
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        shown = true
        var target = start
        target.origin.y = screen.frame.minY
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
private final class ShelfTab: NSView {
    private let noteID: String
    private let onOpen: (String, NSRect?) -> Void
    private let background: NSColor

    init(note: Note, dimmed: Bool, onOpen: @escaping (String, NSRect?) -> Void) {
        self.noteID = note.id
        self.onOpen = onOpen
        let palette = Theme.palette(note.color)
        self.background = palette.background
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] // top corners only
        alphaValue = dimmed ? 0.55 : 1.0
        toolTip = note.title

        let dot = NSImageView(image: Theme.swatch(palette, diameter: 10))
        let label = NSTextField(labelWithString: note.title)
        label.font = Theme.rounded(12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
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

    override func mouseDown(with event: NSEvent) {
        // the sticky expands out of this tab, Dock-style
        let screenRect = window.map { $0.convertToScreen(convert(bounds, to: nil)) }
        onOpen(noteID, screenRect)
    }
}
