import AppKit

/// The window mechanics that make Peel work:
///  - .nonactivatingPanel + isFloatingPanel: becomes key WITHOUT activating the app,
///    so a fullscreen video underneath keeps playing while you type.
///  - .canJoinAllSpaces + .fullScreenAuxiliary: visible on every Space, including
///    over fullscreen apps.
///  - .titled with hidden chrome: keeps the system's edge-drag resizing, which
///    plain borderless windows don't get.
class FloatPanel: NSPanel {
    init(frame: NSRect, resizable: Bool) {
        var style: NSWindow.StyleMask = [.titled, .nonactivatingPanel, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        super.init(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class StickyPanel: FloatPanel {
    weak var sticky: StickyController?

    init(frame: NSRect) {
        super.init(frame: frame, resizable: true)
        minSize = NSSize(width: 220, height: 130)
    }

    override func cancelOperation(_ sender: Any?) {
        sticky?.hide()
    }

    /// Any click anywhere on the sticky solidifies a ghost: header, text,
    /// strip, whatever. Key-window changes alone miss the header-drag case.
    /// Header buttons are exempt so the eye can toggle both ways.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let content = contentView,
           let hit = content.hitTest(event.locationInWindow), !(hit is NSButton) {
            sticky?.stickyClicked()
        }
        super.sendEvent(event)
    }

    /// Main-menu key equivalents don't fire while the app is inactive (the normal
    /// state for a non-activating panel), so the panel dispatches its own.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if sticky?.handleKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
