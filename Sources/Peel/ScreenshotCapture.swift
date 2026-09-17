import AppKit
import ScreenCaptureKit

/// ScreenCaptureKit-powered interactive screenshot capture.
///
/// SCK permissions are tracked by bundle ID (io.barakel.peel), not by code
/// signature. This means the permission survives `make install` rebuilds,
/// unlike the TCC Screen Recording grant that screencapture -i was using.
///
/// The flow: request the display content → capture a frame → show a full-screen
/// selection overlay → let the user drag a region → return the cropped image.
enum ScreenshotCapture {

    typealias Completion = (CGImage?) -> Void

    /// Start an interactive screenshot. On macOS 14+, uses SCK with a custom
    /// selection overlay. Falls back to screencapture -i on older systems.
    static func run(on screen: NSScreen? = nil, completion: @escaping Completion) {
        if #available(macOS 14.0, *) {
            captureViaScreenCaptureKit(preferredScreen: screen, completion: completion)
        } else {
            captureViaSystemTool(completion: completion)
        }
    }

    // MARK: ScreenCaptureKit path (macOS 14+)

    @available(macOS 14.0, *)
    private static func captureViaScreenCaptureKit(preferredScreen: NSScreen?,
                                                    completion: @escaping Completion) {
        // getExcludingDesktopWindows triggers the SCK permission prompt exactly once.
        // Subsequent calls (even after binary changes) reuse the bundle-ID-based grant.
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            DispatchQueue.main.async {
                guard let content, error == nil else {
                    // Permission denied or unavailable — fall back silently
                    captureViaSystemTool(completion: completion)
                    return
                }
                let targetScreen = preferredScreen
                    ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
                    ?? NSScreen.main
                    ?? NSScreen.screens[0]
                // Match the SCDisplay to the NSScreen by pixel dimensions
                let display = content.displays.first(where: {
                    Int($0.width) == Int(targetScreen.frame.width * targetScreen.backingScaleFactor)
                    || Int($0.width) == Int(targetScreen.frame.width)
                }) ?? content.displays.first
                guard let display else { completion(nil); return }
                let screenFrame = targetScreen.frame
        let backingScale = targetScreen.backingScaleFactor
        Task { await capture(display: display, screenFrame: screenFrame,
                             backingScale: backingScale, completion: completion) }
            }
        }
    }

    @available(macOS 14.0, *)
    private static func capture(display: SCDisplay, screenFrame: NSRect,
                                 backingScale: CGFloat, completion: @escaping Completion) async {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // Request native resolution
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        // colorSpaceName takes CFString; omit for default sRGB
        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            await MainActor.run {
                SelectionOverlay.present(screenshot: image, frame: screenFrame, completion: completion)
            }
        } catch {
            await MainActor.run { completion(nil) }
        }
    }

    // MARK: Legacy path (macOS < 14)

    private static func captureViaSystemTool(completion: @escaping Completion) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peel-cap-\(arc4random()).png")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-i", tmp.path]
        proc.terminationHandler = { _ in
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: tmp) }
                guard let img = NSImage(contentsOf: tmp),
                      let cgImage = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else { completion(nil); return }
                completion(cgImage)
            }
        }
        try? proc.run()
    }
}

// MARK: - Selection overlay

/// Full-screen interactive crosshair overlay, identical UX to ⌘⇧4.
/// The captured display screenshot is shown as the background; the selected
/// region is brightened while everything else is dimmed. Esc cancels.
@available(macOS 14.0, *)
private final class SelectionOverlay: NSWindow {
    private let rawImage: CGImage
    private var completion: ScreenshotCapture.Completion?
    private let view: OverlayView

    static func present(screenshot: CGImage, frame: NSRect,
                        completion: @escaping ScreenshotCapture.Completion) {
        let overlay = SelectionOverlay(screenshot: screenshot, frame: frame)
        overlay.completion = completion
        overlay.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
    }

    private init(screenshot: CGImage, frame: NSRect) {
        self.rawImage = screenshot
        self.view = OverlayView(screenshot: screenshot)
        super.init(contentRect: frame, styleMask: [.borderless],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        isOpaque = true
        backgroundColor = .black
        ignoresMouseEvents = false
        contentView = view
        view.frame = frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) } // Escape
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        view.start = event.locationInWindow
        view.current = event.locationInWindow
        view.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        view.current = event.locationInWindow
        view.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        view.current = event.locationInWindow
        guard let rect = view.selectionRect, rect.width > 4, rect.height > 4 else {
            finish(nil); return
        }
        finish(crop(windowRect: rect))
    }

    // MARK: Crop

    private func crop(windowRect: NSRect) -> CGImage? {
        let winH = frame.height
        let sx = CGFloat(rawImage.width) / frame.width
        let sy = CGFloat(rawImage.height) / winH
        // NSWindow: y=0 at bottom. CGImage: y=0 at top → flip Y.
        let cr = CGRect(x: windowRect.minX * sx,
                        y: (winH - windowRect.maxY) * sy,
                        width: windowRect.width * sx,
                        height: windowRect.height * sy)
        return rawImage.cropping(to: cr)
    }

    func finish(_ result: CGImage?) {
        NSCursor.arrow.set()
        orderOut(nil)
        completion?(result)
        completion = nil
    }
}

/// Draws the screenshot + dim layer + live selection rectangle + instruction hint.
@available(macOS 14.0, *)
private final class OverlayView: NSView {
    private let screenshot: CGImage
    var start: NSPoint?
    var current: NSPoint?

    init(screenshot: CGImage) {
        self.screenshot = screenshot
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var selectionRect: NSRect? {
        guard let s = start, let c = current else { return nil }
        return NSRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(c.x - s.x), height: abs(c.y - s.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Full-screen screenshot, slightly dimmed
        ctx.draw(screenshot, in: bounds)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.40).cgColor)
        ctx.fill(bounds)

        if let sel = selectionRect {
            // Show selected region at full brightness
            ctx.saveGState()
            ctx.clip(to: sel)
            ctx.draw(screenshot, in: bounds)
            ctx.restoreGState()
            // Animated dashed border
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [5, 3])
            ctx.stroke(sel.insetBy(dx: 0.5, dy: 0.5))
            // Size badge
            let label = String(format: "%.0f × %.0f", sel.width, sel.height) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.6),
            ]
            label.draw(at: NSPoint(x: sel.midX - label.size(withAttributes: attrs).width / 2,
                                   y: sel.maxY + 4), withAttributes: attrs)
        } else {
            // Instruction hint
            let hint = "Drag to capture a region  ·  esc to cancel" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let sz = hint.size(withAttributes: attrs)
            hint.draw(at: NSPoint(x: (bounds.width - sz.width) / 2,
                                  y: bounds.height * 0.88), withAttributes: attrs)
        }
    }

    // Route mouse events up to the window
    override func mouseDown(with event: NSEvent) { window?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
    override func keyDown(with event: NSEvent) { window?.keyDown(with: event) }
}
