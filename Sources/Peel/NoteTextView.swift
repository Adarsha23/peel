import AppKit
import PeelKit

protocol NoteTextViewDelegate: AnyObject {
    func noteTextDidChange()
    func noteAttachFiles(_ urls: [URL], at index: Int?)
    func noteAttachImageData(_ data: Data, at index: Int?)
    func noteHide()
    /// A /command typed alone on a line + return. True = handled (line is erased).
    func noteCommand(_ command: String) -> Bool
}

/// A plain-text-first editor with live glyph styling:
///   typing "[] " becomes "☐ ", "- " becomes "• ", Enter continues lists,
///   ⌘↩ or clicking a box toggles todos, code fences go monospaced,
///   URLs become clickable. What you see maps 1:1 to markdown on disk.
final class NoteTextView: NSTextView {
    weak var noteDelegate: NoteTextViewDelegate?

    var accent: NSColor = .controlAccentColor {
        didSet {
            linkTextAttributes = [
                .foregroundColor: accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .cursor: NSCursor.pointingHand,
            ]
            restyle()
        }
    }

    var placeholder = "New thought…"

    /// Where this note's attachments live; used to resolve ⟦image⟧ tokens.
    var attachmentsDir: URL?
    private var tokenLinks: [(range: NSRange, url: URL)] = []

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let tokenRegex = try? NSRegularExpression(pattern: Markup.tokenPattern)

    func configure() {
        isRichText = true
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        usesFontPanel = false
        usesFindBar = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        smartInsertDeleteEnabled = false
        textContainerInset = NSSize(width: 10, height: 6)
        typingAttributes = baseAttributes
        linkTextAttributes = [
            .foregroundColor: accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: Theme.bodyFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: NoteTextView.bodyParagraph,
        ]
    }

    private static let bodyParagraph: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2.5
        paragraph.paragraphSpacing = 2
        return paragraph
    }()

    /// Hanging indent so wrapped list items align under their text, not the glyph.
    private static let listParagraph: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2.5
        paragraph.paragraphSpacing = 2
        paragraph.headIndent = 17
        return paragraph
    }()

    // MARK: Styling

    func restyle() {
        guard let storage = textStorage else { return }
        let ns = string as NSString
        let full = NSRange(location: 0, length: ns.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)

        var inFence = false
        var lineStart = 0
        while lineStart < ns.length {
            var lineEnd = 0
            var contentsEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: lineStart, length: 0))
            let lineRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { lineStart = lineEnd }

            if trimmed.hasPrefix("```") {
                storage.addAttribute(.font, value: Theme.monoFont, range: lineRange)
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: lineRange)
                inFence.toggle()
                continue
            }
            if inFence {
                storage.addAttribute(.font, value: Theme.monoFont, range: lineRange)
                continue
            }
            if trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ") {
                storage.addAttribute(.font, value: Theme.headingFont, range: lineRange)
                continue
            }

            let indentLength = line.prefix { $0 == " " || $0 == "\t" }.count
            let glyphLocation = lineStart + indentLength
            if let first = trimmed.unicodeScalars.first {
                if first == "☐" || first == "☑" || first == "•" {
                    storage.addAttribute(.paragraphStyle, value: NoteTextView.listParagraph,
                                         range: lineRange)
                }
                switch first {
                case "☐", "•":
                    storage.addAttribute(.foregroundColor, value: accent,
                                         range: NSRange(location: glyphLocation, length: 1))
                case "☑":
                    storage.addAttribute(.foregroundColor, value: accent.withAlphaComponent(0.5),
                                         range: NSRange(location: glyphLocation, length: 1))
                    let rest = NSRange(location: glyphLocation + 1,
                                       length: max(0, lineRange.upperBound - glyphLocation - 1))
                    if rest.length > 0 {
                        storage.addAttribute(.strikethroughStyle,
                                             value: NSUnderlineStyle.single.rawValue, range: rest)
                        storage.addAttribute(.strikethroughColor,
                                             value: NSColor.tertiaryLabelColor, range: rest)
                        storage.addAttribute(.foregroundColor,
                                             value: NSColor.secondaryLabelColor, range: rest)
                    }
                default: break
                }
            }
            if trimmed.hasPrefix("@remind") {
                storage.addAttribute(.foregroundColor, value: NSColor.systemOrange,
                                     range: NSRange(location: glyphLocation, length: 7))
            }
        }

        if let detector = NoteTextView.linkDetector {
            detector.enumerateMatches(in: string, range: full) { match, _, _ in
                if let match, let url = match.url {
                    storage.addAttribute(.link, value: url, range: match.range)
                }
            }
        }

        // ⟦image-1.png⟧ tokens: accent pill, click to open, dimmed if the file is gone
        tokenLinks = []
        if let dir = attachmentsDir, let regex = NoteTextView.tokenRegex {
            regex.enumerateMatches(in: string, range: full) { match, _, _ in
                guard let match else { return }
                let name = ns.substring(with: match.range(at: 1))
                let url = dir.appendingPathComponent(name)
                let exists = FileManager.default.fileExists(atPath: url.path)
                storage.addAttribute(.font, value: Theme.rounded(12, weight: .medium), range: match.range)
                storage.addAttribute(.backgroundColor,
                                     value: accent.withAlphaComponent(0.13), range: match.range)
                storage.addAttribute(.foregroundColor,
                                     value: exists ? accent : NSColor.tertiaryLabelColor,
                                     range: match.range)
                if exists {
                    storage.addAttribute(.cursor, value: NSCursor.pointingHand, range: match.range)
                    tokenLinks.append((match.range, url))
                }
            }
        }
        storage.endEditing()
        typingAttributes = baseAttributes
    }

    func insertPlain(_ text: String, at index: Int?) {
        let length = (string as NSString).length
        let location = min(index ?? selectedRange().location, length)
        insertText(text, replacementRange: NSRange(location: location, length: 0))
    }

    // MARK: Editing behaviors

    override func didChangeText() {
        super.didChangeText()
        applyAutoSubstitutions()
        restyle()
        needsDisplay = true
        noteDelegate?.noteTextDidChange()
    }

    /// "[] " → "☐ ", "[x] " → "☑ ", "- " → "• " when typed at the start of a line.
    private func applyAutoSubstitutions() {
        let selection = selectedRange()
        guard selection.length == 0, selection.location > 0 else { return }
        let ns = string as NSString
        var lineStart = 0
        ns.getLineStart(&lineStart, end: nil, contentsEnd: nil,
                        for: NSRange(location: min(selection.location, ns.length), length: 0))
        guard selection.location > lineStart else { return }
        let prefix = ns.substring(with: NSRange(location: lineStart,
                                                length: selection.location - lineStart))
        let indent = prefix.prefix { $0 == " " || $0 == "\t" }
        let token = String(prefix.dropFirst(indent.count))
        let substitutions = ["[] ": "☐ ", "[x] ": "☑ ", "[X] ": "☑ ", "- ": "• ", "* ": "• "]
        guard let replacement = substitutions[token] else { return }
        let tokenRange = NSRange(location: lineStart + indent.count,
                                 length: (token as NSString).length)
        if shouldChangeText(in: tokenRange, replacementString: replacement) {
            replaceCharacters(in: tokenRange, with: replacement)
            didChangeText()
        }
    }

    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let selection = selectedRange()
        guard selection.location <= ns.length else { return super.insertNewline(sender) }
        var lineStart = 0
        var contentsEnd = 0
        ns.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd,
                        for: NSRange(location: selection.location, length: 0))
        let line = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let content = String(line.dropFirst(indent.count))

        // Slash commands: "/help" + return runs the command and erases the line.
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/"), trimmed.count > 1, !trimmed.contains(" "),
           noteDelegate?.noteCommand(String(trimmed.dropFirst()).lowercased()) == true {
            let lineRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
            if shouldChangeText(in: lineRange, replacementString: "") {
                replaceCharacters(in: lineRange, with: "")
                didChangeText()
            }
            return
        }

        func endOrContinueList(marker: String, nextMarker: String, rest: Substring) {
            if rest.trimmingCharacters(in: .whitespaces).isEmpty {
                // Enter on an empty list item ends the list.
                let markerRange = NSRange(location: lineStart + indent.count,
                                          length: (marker as NSString).length)
                if shouldChangeText(in: markerRange, replacementString: "") {
                    replaceCharacters(in: markerRange, with: "")
                    didChangeText()
                }
            } else {
                super.insertNewline(sender)
                insertText(indent + nextMarker, replacementRange: selectedRange())
            }
        }

        if content.hasPrefix("☐ ") { return endOrContinueList(marker: "☐ ", nextMarker: "☐ ", rest: content.dropFirst(2)) }
        if content.hasPrefix("☑ ") { return endOrContinueList(marker: "☑ ", nextMarker: "☐ ", rest: content.dropFirst(2)) }
        if content.hasPrefix("• ") { return endOrContinueList(marker: "• ", nextMarker: "• ", rest: content.dropFirst(2)) }

        let digits = content.prefix { $0.isNumber }
        if !digits.isEmpty, content.dropFirst(digits.count).hasPrefix(". ") {
            let marker = "\(digits). "
            let next = "\((Int(digits) ?? 0) + 1). "
            return endOrContinueList(marker: marker, nextMarker: next,
                                     rest: content.dropFirst(marker.count))
        }
        super.insertNewline(sender)
    }

    /// ⌘↩ — toggle the todo state of the current line (or make it a todo).
    @objc func toggleTodo(_ sender: Any?) {
        let ns = string as NSString
        let lines = ns.lineRange(for: selectedRange())
        var edits: [(NSRange, String)] = []
        var lineStart = lines.location
        while lineStart < lines.upperBound || (lineStart == lines.location && lines.length == 0) {
            var lineEnd = 0
            var contentsEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: lineStart, length: 0))
            let line = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
            let indentLength = line.prefix { $0 == " " || $0 == "\t" }.count
            let glyphLocation = lineStart + indentLength
            let content = String(line.dropFirst(indentLength))
            if content.hasPrefix("☐") {
                edits.append((NSRange(location: glyphLocation, length: 1), "☑"))
            } else if content.hasPrefix("☑") {
                edits.append((NSRange(location: glyphLocation, length: 1), "☐"))
            } else if content.hasPrefix("• ") {
                edits.append((NSRange(location: glyphLocation, length: 2), "☐ "))
            } else {
                edits.append((NSRange(location: glyphLocation, length: 0), "☐ "))
            }
            if lineEnd <= lineStart { break }
            lineStart = lineEnd
            if lines.length == 0 { break }
        }
        for (range, replacement) in edits.reversed() {
            if shouldChangeText(in: range, replacementString: replacement) {
                replaceCharacters(in: range, with: replacement)
            }
        }
        didChangeText()
    }

    /// Click a ⟦image⟧ token to view it; click a ☐/☑ glyph to toggle it.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        for (range, url) in tokenLinks where NSLocationInRange(index, range) {
            NSWorkspace.shared.open(url.resolvingSymlinksInPath())
            return
        }
        let ns = string as NSString
        for candidate in [index, index - 1] where candidate >= 0 && candidate < ns.length {
            let ch = ns.character(at: candidate)
            if ch == 0x2610 || ch == 0x2611 { // ☐ ☑
                let replacement = ch == 0x2610 ? "☑" : "☐"
                let range = NSRange(location: candidate, length: 1)
                if shouldChangeText(in: range, replacementString: replacement) {
                    replaceCharacters(in: range, with: replacement)
                    didChangeText()
                }
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        noteDelegate?.noteHide()
    }

    // MARK: Paste & drop

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            noteDelegate?.noteAttachFiles(urls, at: selectedRange().location)
            return
        }
        if pasteboard.string(forType: .string) == nil,
           let data = NoteTextView.imageData(from: pasteboard) {
            noteDelegate?.noteAttachImageData(data, at: selectedRange().location)
            return
        }
        pasteAsPlainText(sender) // strip rogue formatting, always
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let dropPoint = convert(sender.draggingLocation, from: nil)
        let dropIndex = characterIndexForInsertion(at: dropPoint)
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            noteDelegate?.noteAttachFiles(urls, at: dropIndex)
            return true
        }
        if pasteboard.string(forType: .string) == nil,
           let data = NoteTextView.imageData(from: pasteboard) {
            noteDelegate?.noteAttachImageData(data, at: dropIndex)
            return true
        }
        return super.performDragOperation(sender) // text / URLs insert as text
    }

    static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png) { return data }
        if let data = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: data) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    // MARK: Placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Theme.bodyFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let origin = NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height)
            (placeholder as NSString).draw(at: origin, withAttributes: attributes)
        }
    }
}
