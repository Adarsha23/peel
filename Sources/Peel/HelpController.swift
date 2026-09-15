import AppKit

/// The /help cheatsheet: a floating, non-activating panel — no alert, no app
/// activation, nothing under it pauses. Esc or clicking away dismisses it.
final class HelpController: NSObject, NSWindowDelegate {
    private var panel: HelpPanel?

    func toggle() {
        if panel?.isVisible == true { panel?.orderOut(nil) } else { show() }
    }

    func show() {
        buildIfNeeded()
        guard let panel else { return }
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: visible.midX - panel.frame.width / 2,
                                           y: visible.minY + visible.height * 0.82))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.animator().alphaValue = 1
    }

    func windowDidResignKey(_ notification: Notification) {
        panel?.orderOut(nil)
    }

    private func buildIfNeeded() {
        guard panel == nil else { return }
        let width: CGFloat = 430
        let label = NSTextField(labelWithAttributedString: HelpController.cheatsheet())
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = width - 48

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Theme.roundedMask(radius: 14)
        effect.addSubview(label)

        let height = label.fittingSize.height + 44
        let panel = HelpPanel(frame: NSRect(x: 0, y: 0, width: width, height: height),
                              resizable: false)
        panel.delegate = self
        panel.contentView = effect
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 24),
            label.topAnchor.constraint(equalTo: effect.topAnchor, constant: 22),
        ])
        self.panel = panel
    }

    // MARK: Content

    private static func cheatsheet() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let keyStyle = NSMutableParagraphStyle()
        keyStyle.tabStops = [NSTextTab(textAlignment: .left, location: 118)]
        keyStyle.lineSpacing = 3.5
        keyStyle.headIndent = 118

        func section(_ title: String) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = result.length == 0 ? 0 : 14
            style.paragraphSpacing = 5
            result.append(NSAttributedString(string: title + "\n", attributes: [
                .font: Theme.rounded(11, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .kern: 0.8,
                .paragraphStyle: style,
            ]))
        }

        func row(_ key: String, _ description: String) {
            result.append(NSAttributedString(string: key + "\t", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: keyStyle,
            ]))
            result.append(NSAttributedString(string: description + "\n", attributes: [
                .font: Theme.rounded(12),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: keyStyle,
            ]))
        }

        section("GLOBAL")
        row("⌘⇧space", "show · focus · press again to hide")
        row("⌃⌥V", "new sticky from whatever's on the clipboard")
        row("screen edge", "push the cursor in: shelf of all stickies (pick the side in the menu bar)")

        section("IN A STICKY")
        row("esc / ⌘W", "hide sticky")
        row("⌘esc", "hide all stickies")
        row("⌘T / ⌃⌥N", "new sticky")
        row("⌘return", "toggle todo on this line")
        row("⌘⌫", "delete line, repeats upward")
        row("2×click header", "collapse / expand")
        row("idle sticky", "fades see-through after 4s · click it to bring it back")
        row("⌃⌥F", "search notes")
        row("⌃⌥B", "push behind windows / bring back")
        row("⌃⌥G", "see through right now (also the eye in the header)")
        row("⌃⌥L", "lock opaque, so it never fades")
        row("⌃⌥S", "screenshot into note")
        row("⌃⌥A", "archive note")
        row("⌃⌥1–7", "change color")

        section("FORMATTING")
        row("⌘B  ⌘I  ⌘E", "**bold** · *italic* · `code`, toggles the selection")
        row("⌘⇧X  ⌘⇧H", "~~strikethrough~~ · ==highlight==")
        row("#  ##", "headings")
        row("⌘+  ⌘−  ⌘0", "per-sticky text zoom · reset")

        section("TYPING")
        row("/", "on an empty line: command menu, type to filter, click to apply")
        row("[] + space", "todo")
        row("- + space", "bullet")
        row("``` … ```", "code block")
        row("@remind", "in 20 min · every weekday 9am · click the tag to pick")
        row("240*1.18=", "typing = after math inserts the result")
        row("[[note title]]", "link to another sticky, click to jump, [[ offers titles")
        row("⟦image-1.png⟧", "click to view · drop/paste to add · text inside is searchable")
        row("drag a sticky", "edges magnetize to other stickies and the screen")

        section("SLASH, TYPE ON ITS OWN LINE + RETURN")
        row("/help", "this cheatsheet")
        row("/new  /search", "sticky · search")
        row("/hide  /behind", "hide · layer toggle")
        row("/ghost", "instant see-through, click to solidify")
        row("/lock", "pin the sticky opaque")
        row("/links", "notes this one links to and from (the link badge too)")
        row("/archive  /shot", "archive · screenshot")
        row("/remind", "pick a time, or write it: /remind in 20 min pay rent")
        row("/date  /time", "insert date · time")
        row("/copy  /open", "copy note as markdown · show in Finder")
        row("/count /trim", "stats · tidy whitespace (also /lower /upper)")
        row("/yellow …", "any color: cream blue green lavender pink graphite")

        section("CONFIG.JSON")
        row("keys", "remap every in-sticky shortcut, pipe for combos, none unbinds")
        row("shelfEdge · hotkeys", "bottom/top/left/right · global hotkey specs")

        section("TERMINAL")
        row("peel", "new · list · search · today · show <id> · ui <cmd>")
        row("peel doctor", "reminders not showing? checks permission + lists pending")
        return result
    }
}

private final class HelpPanel: FloatPanel {
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
