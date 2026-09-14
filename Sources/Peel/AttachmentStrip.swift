import AppKit
import PeelKit

/// Horizontal row of attachment chips below the note text. The strip mirrors the
/// note's attachments/ folder exactly — no separate bookkeeping to corrupt.
final class AttachmentStrip: NSView {
    var onRemove: ((URL) -> Void)?

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var heightConstraint: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let clip = NSClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = stack
        addSubview(scroll)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            heightConstraint,
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(urls: [URL]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for url in urls {
            let chip = ChipView(url: url)
            chip.onRemove = { [weak self] in self?.onRemove?(url) }
            stack.addArrangedSubview(chip)
        }
        isHidden = urls.isEmpty
        heightConstraint.constant = urls.isEmpty ? 0 : 56
    }
}

private final class ChipView: NSView {
    let url: URL
    var onRemove: (() -> Void)?


    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        toolTip = url.lastPathComponent

        let isImage = OCR.imageExtensions.contains(url.pathExtension.lowercased())
        if isImage, let thumb = ChipView.thumbnail(for: url) {
            let imageView = NSImageView(image: thumb)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(imageView)
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: 44),
                heightAnchor.constraint(equalToConstant: 44),
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
                imageView.topAnchor.constraint(equalTo: topAnchor),
                imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        } else {
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
            icon.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: shortName(url.lastPathComponent))
            label.font = Theme.rounded(11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            addSubview(label)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 28),
                widthAnchor.constraint(lessThanOrEqualToConstant: 160),
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        // resolve symlinks so >100MB references open the original
        NSWorkspace.shared.open(url.resolvingSymlinksInPath())
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openFile), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealFile), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPath), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove", action: #selector(removeFile), keyEquivalent: "").target = self
        return menu
    }

    @objc private func openFile() { NSWorkspace.shared.open(url.resolvingSymlinksInPath()) }
    @objc private func revealFile() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    @objc private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
    @objc private func removeFile() { onRemove?() }

    private func shortName(_ name: String) -> String {
        name.count > 24 ? name.prefix(12) + "…" + name.suffix(9) : name
    }

    private static func thumbnail(for url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        // ponytail: full decode then downscale; QuickLookThumbnailing if this ever feels slow
        let thumb = NSImage(size: NSSize(width: 88, height: 88))
        thumb.lockFocus()
        let side = min(image.size.width, image.size.height)
        let crop = NSRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2,
                          width: side, height: side)
        image.draw(in: NSRect(x: 0, y: 0, width: 88, height: 88), from: crop,
                   operation: .copy, fraction: 1)
        thumb.unlockFocus()
        return thumb
    }
}
