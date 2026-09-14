import AppKit

/// Peel's own reminder alarm: a floating card that uses the same panel tech as
/// the stickies — so unlike system banners it provably shows over fullscreen
/// apps, and it stays until acted on. Chime included.
final class ReminderAlert {
    private var panel: FloatPanel?
    private var noteID = ""
    private var openHandler: ((String) -> Void)?
    private var snoozeHandler: ((String, String) -> Void)?
    private var text = ""

    func show(noteID: String, text: String, title: String,
              onOpen: @escaping (String) -> Void,
              onSnooze: @escaping (String, String) -> Void) {
        self.noteID = noteID
        self.text = text
        self.openHandler = onOpen
        self.snoozeHandler = onSnooze
        dismiss()

        let panel = FloatPanel(frame: NSRect(x: 0, y: 0, width: 360, height: 96), resizable: false)
        panel.level = .statusBar // above the stickies

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Theme.roundedMask(radius: 14)

        let icon = NSTextField(labelWithString: "⏰")
        icon.font = .systemFont(ofSize: 24)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Theme.rounded(13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        let bodyLabel = NSTextField(labelWithString: text)
        bodyLabel.font = Theme.rounded(12)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.maximumNumberOfLines = 2

        let openButton = NSButton(title: "Open Note", target: self, action: #selector(openPressed))
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.keyEquivalent = "\r"
        let snoozeButton = NSButton(title: "+10 min", target: self, action: #selector(snoozePressed))
        snoozeButton.bezelStyle = .rounded
        snoozeButton.controlSize = .small
        let doneButton = NSButton(title: "Done", target: self, action: #selector(dismissPressed))
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .small

        for view in [icon, titleLabel, bodyLabel, openButton, snoozeButton, doneButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(view)
        }
        panel.contentView = effect
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: effect.trailingAnchor, constant: -14),
            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            bodyLabel.trailingAnchor.constraint(lessThanOrEqualTo: effect.trailingAnchor, constant: -14),
            openButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            openButton.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10),
            snoozeButton.leadingAnchor.constraint(equalTo: openButton.trailingAnchor, constant: 8),
            snoozeButton.centerYAnchor.constraint(equalTo: openButton.centerYAnchor),
            doneButton.leadingAnchor.constraint(equalTo: snoozeButton.trailingAnchor, constant: 8),
            doneButton.centerYAnchor.constraint(equalTo: openButton.centerYAnchor),
        ])

        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin = NSPoint(x: visible.maxX - frame.width - 16,
                               y: visible.maxY - frame.height - 16)
        var start = frame
        start.origin.y += 24
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
        self.panel = panel

        if let url = Bundle.main.url(forResource: "peel-chime", withExtension: "wav"),
           let sound = NSSound(contentsOf: url, byReference: true) {
            sound.play()
        }
        // No auto-dismiss: a reminder that fires while you're away (screensaver,
        // lunch) must still be waiting when you come back. Done/snooze clears it.
    }

    @objc private func openPressed() {
        let id = noteID
        dismiss()
        openHandler?(id)
    }

    @objc private func snoozePressed() {
        let id = noteID
        let body = text
        dismiss()
        snoozeHandler?(id, body)
    }

    @objc private func dismissPressed() { dismiss() }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}
