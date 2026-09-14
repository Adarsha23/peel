import AppKit

/// Peel's reminder alarm: a floating card in the note's own paper color — the
/// same panel tech as the stickies, so it provably shows over fullscreen apps,
/// and it stays until acted on. Click the card to open the note.
final class ReminderAlert {
    private var panel: FloatPanel?
    private var noteID = ""
    private var text = ""
    private var openHandler: ((String) -> Void)?
    private var snoozeHandler: ((String, String) -> Void)?

    func show(noteID: String, text: String, title: String, palette: Theme.Palette,
              onOpen: @escaping (String) -> Void,
              onSnooze: @escaping (String, String) -> Void) {
        self.noteID = noteID
        self.text = text
        self.openHandler = onOpen
        self.snoozeHandler = onSnooze
        dismiss()

        let width: CGFloat = 384
        let panel = FloatPanel(frame: NSRect(x: 0, y: 0, width: width, height: 116),
                               resizable: false)
        panel.level = .statusBar // above the stickies

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Theme.roundedMask(radius: 16)

        let card = CardView()
        card.onClick = { [weak self] in self?.openPressed() }
        card.color = palette.background
        card.translatesAutoresizingMaskIntoConstraints = false

        // slim accent spine — the "this is a Peel note" signature
        let spine = NSView()
        spine.wantsLayer = true
        spine.layer?.cornerRadius = 2
        spine.layer?.backgroundColor = palette.accent.cgColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Theme.rounded(13.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        // the title yields (truncates) before it can push the time off the card
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let timeLabel = NSTextField(labelWithString: timeFormatter.string(from: Date()))
        timeLabel.font = Theme.rounded(11)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let bodyLabel = NSTextField(wrappingLabelWithString: text)
        bodyLabel.font = Theme.rounded(13)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.maximumNumberOfLines = 4 // the card grows; only novels truncate
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.preferredMaxLayoutWidth = width - 48

        let open = textButton("Open Note", color: palette.accent, weight: .semibold,
                              action: #selector(openPressed))
        let snooze = textButton("Snooze 10 min", color: .secondaryLabelColor, weight: .medium,
                                action: #selector(snoozePressed))
        let done = textButton("Done", color: .secondaryLabelColor, weight: .medium,
                              action: #selector(dismissPressed))

        effect.addSubview(card)
        for view in [spine, titleLabel, timeLabel, bodyLabel, open, snooze, done] {
            view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(view)
        }
        panel.contentView = effect

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            card.topAnchor.constraint(equalTo: effect.topAnchor),
            card.bottomAnchor.constraint(equalTo: effect.bottomAnchor),

            spine.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            spine.topAnchor.constraint(equalTo: effect.topAnchor, constant: 16),
            spine.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -16),
            spine.widthAnchor.constraint(equalToConstant: 4),

            titleLabel.leadingAnchor.constraint(equalTo: spine.trailingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: effect.topAnchor, constant: 15),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -10),

            timeLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            timeLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            bodyLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),

            open.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            open.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 14),
            open.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -13),
            snooze.leadingAnchor.constraint(equalTo: open.trailingAnchor, constant: 18),
            snooze.centerYAnchor.constraint(equalTo: open.centerYAnchor),
            done.leadingAnchor.constraint(equalTo: snooze.trailingAnchor, constant: 18),
            done.centerYAnchor.constraint(equalTo: open.centerYAnchor),
        ])

        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.size.height = max(104, effect.fittingSize.height) // grow with the message
        frame.origin = NSPoint(x: visible.maxX - frame.width - 16,
                               y: visible.maxY - frame.height - 16)
        var start = frame
        start.origin.y += 26
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
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

    private func textButton(_ title: String, color: NSColor, weight: NSFont.Weight,
                            action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.rounded(12.5, weight: weight),
            .foregroundColor: color,
        ])
        button.setButtonType(.momentaryPushIn)
        return button
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
        var target = panel.frame
        target.origin.y += 18
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(target, display: true)
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

/// The note-colored paper of the card; clicking anywhere opens the note.
private final class CardView: TintView {
    var onClick: (() -> Void)?

    init() {
        super.init(cornerRadius: 16)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
