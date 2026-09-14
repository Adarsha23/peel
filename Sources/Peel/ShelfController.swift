import AppKit
import PeelKit

/// Which screen edge the shelf lives on. Vertical edges get a column of tabs.
enum ShelfEdge: String, CaseIterable {
    case bottom, top, left, right

    var isHorizontal: Bool { self == .bottom || self == .top }

    /// Rounded corners face away from the screen edge.
    var innerCorners: CACornerMask {
        switch self {
        case .bottom: return [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        case .top: return [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        case .left: return [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        case .right: return [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        }
    }
}

/// The shelf: push the cursor to a screen edge (configurable, bottom by
/// default) and every note appears as a tab (first line = label, newest
/// first). Click one to open it.
/// Uses a cheap mouse-position poll — no event taps, no permissions.
final class ShelfController {
    private unowned let app: AppDelegate
    private var panel: FloatPanel?
    private var pollTimer: Timer?
    private var shown = false
    private var holdUntil = Date.distantPast // manual (peel ui shelf) shows linger
    private var slideVector = CGVector(dx: 0, dy: -40) // hide direction, set on layout

    private(set) var edge: ShelfEdge = .bottom
    private var thickness: CGFloat { edge.isHorizontal ? 40 : 220 }

    init(app: AppDelegate) {
        self.app = app
    }

    func start(edge: ShelfEdge) {
        self.edge = edge
        // ponytail: 0.15s NSEvent.mouseLocation poll beats a CGEventTap that
        // would drag in the Accessibility permission
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func setEdge(_ newEdge: ShelfEdge) {
        if shown { hide() }
        edge = newEdge
    }

    private func poll() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
        else { return }
        let f = screen.frame
        let onEdge: Bool
        let away: Bool
        // corners stay free: hot corners live there
        switch edge {
        case .bottom:
            let clear = mouse.x > f.minX + 80 && mouse.x < f.maxX - 80
            onEdge = mouse.y <= f.minY + 1.5 && clear
            away = mouse.y > f.minY + thickness + 60
        case .top:
            let clear = mouse.x > f.minX + 80 && mouse.x < f.maxX - 80
            onEdge = mouse.y >= f.maxY - 1.5 && clear
            away = mouse.y < f.maxY - thickness - 60
        case .left:
            let clear = mouse.y > f.minY + 80 && mouse.y < f.maxY - 80
            onEdge = mouse.x <= f.minX + 1.5 && clear
            away = mouse.x > f.minX + thickness + 60
        case .right:
            let clear = mouse.y > f.minY + 80 && mouse.y < f.maxY - 80
            onEdge = mouse.x >= f.maxX - 1.5 && clear
            away = mouse.x < f.maxX - thickness - 60
        }
        if !shown, onEdge {
            show(on: screen)
        } else if shown, away, Date() > holdUntil {
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
        stack.orientation = edge.isHorizontal ? .horizontal : .vertical
        switch edge {
        case .bottom: stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 0, right: 8)
        case .top: stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 6, right: 8)
        case .left: stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 6)
        case .right: stack.edgeInsets = NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 0)
        }
        var anyVisible = false
        for note in notes.prefix(12) {
            let isVisible = app.controllers[note.id]?.panel.isVisible == true
            anyVisible = anyVisible || isVisible
            let tab = ShelfTab(note: note, dimmed: isVisible, closable: isVisible, edge: edge,
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
            stack.addArrangedSubview(CloseAllTab(edge: edge) { [weak self] in
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
        let f = screen.frame
        let fit = stack.fittingSize
        let target: NSRect
        switch edge {
        case .bottom:
            let width = min(fit.width, f.width - 40)
            target = NSRect(x: f.midX - width / 2, y: f.minY, width: width, height: 40)
            slideVector = CGVector(dx: 0, dy: -40)
        case .top:
            let width = min(fit.width, f.width - 40)
            target = NSRect(x: f.midX - width / 2, y: f.maxY - 40, width: width, height: 40)
            slideVector = CGVector(dx: 0, dy: 40)
        case .left:
            let height = min(fit.height, f.height - 160)
            target = NSRect(x: f.minX, y: f.midY - height / 2, width: fit.width, height: height)
            slideVector = CGVector(dx: -fit.width, dy: 0)
        case .right:
            let height = min(fit.height, f.height - 160)
            target = NSRect(x: f.maxX - fit.width, y: f.midY - height / 2,
                            width: fit.width, height: height)
            slideVector = CGVector(dx: fit.width, dy: 0)
        }
        if !animateIn {
            panel.setFrame(target, display: true)
            return
        }
        var start = target
        start.origin.x += slideVector.dx
        start.origin.y += slideVector.dy
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
        target.origin.x += slideVector.dx
        target.origin.y += slideVector.dy
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
    private let edge: ShelfEdge
    private let dot: NSImageView
    private let closeButton = NSButton()

    init(note: Note, dimmed: Bool, closable: Bool, edge: ShelfEdge,
         onOpen: @escaping (String, NSRect?) -> Void,
         onClose: @escaping (String) -> Void) {
        self.noteID = note.id
        self.onOpen = onOpen
        self.onClose = onClose
        self.closable = closable
        self.edge = edge
        let palette = Theme.palette(note.color)
        self.background = palette.background
        self.dot = NSImageView(image: Theme.swatch(palette, diameter: 10))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.maskedCorners = edge.innerCorners
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
        var sizing = [
            heightAnchor.constraint(equalToConstant: 34),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200),
        ]
        if !edge.isHorizontal {
            sizing.append(widthAnchor.constraint(equalToConstant: 190)) // column tabs align
        }
        NSLayoutConstraint.activate(sizing + [
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

    init(edge: ShelfEdge, onCloseAll: @escaping () -> Void) {
        self.onCloseAll = onCloseAll
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.maskedCorners = edge.innerCorners
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
