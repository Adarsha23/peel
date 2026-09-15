import AppKit
import PeelKit

protocol NoteTextViewDelegate: AnyObject {
    func noteTextDidChange()
    func noteAttachFiles(_ urls: [URL], at index: Int?)
    func noteAttachImageData(_ data: Data, at index: Int?)
    func noteHide()
    /// A /command typed alone on a line + return. True = handled (line is erased).
    func noteCommand(_ command: String) -> Bool
    /// Click on an @remind token — open the time picker.
    func noteRemindClicked(tokenRange: NSRange, dateRange: NSRange?)
    /// "/" typed on an empty line — show the command menu.
    func noteSlashTyped(slashAt location: Int)
    /// Click on a [[wiki link]] — jump to (or create) that note.
    func noteOpenWiki(_ title: String)
    /// "[[" just typed — offer note titles to complete.
    func noteWikiTyped(at location: Int)
    /// Does a note with this title exist? (drives link styling)
    func noteWikiExists(_ title: String) -> Bool
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
    private var remindTokens: [(token: NSRange, dateRange: NSRange?)] = []
    private var wikiLinks: [(range: NSRange, title: String)] = []

    /// Per-sticky zoom (⌘+ / ⌘−); all derived fonts scale from this.
    var baseFontSize: CGFloat = 13 {
        didSet { restyle() }
    }

    private var bodyFont: NSFont { Theme.rounded(baseFontSize) }
    private var boldFont: NSFont { Theme.rounded(baseFontSize, weight: .semibold) }
    private var headingFont: NSFont { Theme.rounded(baseFontSize + 2, weight: .semibold) }
    private var monoFont: NSFont { NSFont.monospacedSystemFont(ofSize: baseFontSize - 1, weight: .regular) }

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let tokenRegex = try? NSRegularExpression(pattern: Markup.tokenPattern)

    // Inline markdown, styled live with the markers dimmed. Lookarounds keep
    // *italic* from matching inside **bold**.
    private static let boldRegex = try! NSRegularExpression(pattern: "\\*\\*([^*\\n]+)\\*\\*")
    private static let italicRegex = try! NSRegularExpression(pattern: "(?<!\\*)\\*([^*\\n]+)\\*(?!\\*)")
    private static let underscoreRegex = try! NSRegularExpression(pattern: "(?<![\\w_])_([^_\\n]+)_(?![\\w_])")
    private static let codeSpanRegex = try! NSRegularExpression(pattern: "`([^`\\n]+)`")
    private static let strikeRegex = try! NSRegularExpression(pattern: "~~([^~\\n]+)~~")
    private static let highlightRegex = try! NSRegularExpression(pattern: "==([^=\\n]+)==")
    private static let wikiRegex = try! NSRegularExpression(pattern: "\\[\\[([^\\]\\n]+)\\]\\]")

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
            .font: bodyFont,
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

        remindTokens = []
        var inFence = false
        var seenTitleLine = false
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
                storage.addAttribute(.font, value: monoFont, range: lineRange)
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: lineRange)
                inFence.toggle()
                continue
            }
            if inFence {
                storage.addAttribute(.font, value: monoFont, range: lineRange)
                continue
            }
            if trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ") {
                storage.addAttribute(.font, value: headingFont, range: lineRange)
                seenTitleLine = true
                continue
            }
            // The first line is the note's header — it names the sticky
            // everywhere (shelf tabs, search, peel list), so render it as one.
            if !seenTitleLine, !trimmed.isEmpty {
                seenTitleLine = true
                if !trimmed.hasPrefix("![") {
                    storage.addAttribute(.font, value: boldFont, range: lineRange)
                }
            }
            styleInline(storage, in: lineRange)

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
            // @remind lines: live feedback on whether a time was understood.
            if trimmed.hasPrefix("@remind") {
                let tokenRange = NSRange(location: glyphLocation, length: 7)
                storage.addAttribute(.cursor, value: NSCursor.pointingHand, range: tokenRange)
                if let match = When.detect(in: line) {
                    let dateRange = NSRange(location: lineStart + match.range.location,
                                            length: match.range.length)
                    storage.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: tokenRange)
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                         range: dateRange)
                    storage.addAttribute(.underlineColor, value: NSColor.systemOrange, range: dateRange)
                    let when = NoteTextView.remindTip.string(from: match.date)
                    let tip = match.repeats.label.map { "Repeats \($0), next \(when)" }
                        ?? "Reminder: \(when)"
                    storage.addAttribute(.toolTip, value: tip, range: lineRange)
                    remindTokens.append((tokenRange, dateRange))
                } else {
                    storage.addAttribute(.foregroundColor, value: NSColor.systemRed, range: tokenRange)
                    storage.addAttribute(
                        .toolTip,
                        value: "No time recognized, click @remind to pick one, or write e.g. “tomorrow 9am” or “Sep 20, 2:30 PM”",
                        range: lineRange)
                    remindTokens.append((tokenRange, nil))
                }
            }
            // @expire lines: purple token, the note self-archives at that time
            if trimmed.hasPrefix("@expire") {
                let tokenRange = NSRange(location: glyphLocation, length: 7)
                if let match = When.detect(in: line) {
                    let dateRange = NSRange(location: lineStart + match.range.location,
                                            length: match.range.length)
                    storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: tokenRange)
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                         range: dateRange)
                    storage.addAttribute(.underlineColor, value: NSColor.systemPurple, range: dateRange)
                    storage.addAttribute(.toolTip,
                                         value: "Archives itself \(NoteTextView.remindTip.string(from: match.date))",
                                         range: lineRange)
                } else {
                    storage.addAttribute(.foregroundColor, value: NSColor.systemRed, range: tokenRange)
                    storage.addAttribute(.toolTip,
                                         value: "No time recognized, write e.g. “in 10 min” or “today 6pm”",
                                         range: lineRange)
                }
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
                storage.addAttribute(.font, value: Theme.rounded(baseFontSize - 1, weight: .medium), range: match.range)
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

        // [[wiki links]] — pill if the target note exists, dimmed if not (yet)
        wikiLinks = []
        NoteTextView.wikiRegex.enumerateMatches(in: string, range: full) { match, _, _ in
            guard let match else { return }
            let title = ns.substring(with: match.range(at: 1))
            let exists = noteDelegate?.noteWikiExists(title) ?? false
            storage.addAttribute(.font, value: Theme.rounded(baseFontSize - 1, weight: .medium),
                                 range: match.range)
            storage.addAttribute(.backgroundColor, value: accent.withAlphaComponent(0.13),
                                 range: match.range)
            storage.addAttribute(.foregroundColor,
                                 value: exists ? accent : NSColor.tertiaryLabelColor,
                                 range: match.range)
            storage.addAttribute(.cursor, value: NSCursor.pointingHand, range: match.range)
            wikiLinks.append((match.range, title))
        }
        storage.endEditing()
        typingAttributes = baseAttributes
    }

    private func styleInline(_ storage: NSTextStorage, in lineRange: NSRange) {
        func apply(_ regex: NSRegularExpression, markerLength: Int,
                   _ style: (NSRange) -> Void) {
            regex.enumerateMatches(in: string, range: lineRange) { match, _, _ in
                guard let match else { return }
                style(match.range(at: 1))
                let dim = NSColor.tertiaryLabelColor
                storage.addAttribute(.foregroundColor, value: dim,
                                     range: NSRange(location: match.range.location, length: markerLength))
                storage.addAttribute(.foregroundColor, value: dim,
                                     range: NSRange(location: match.range.upperBound - markerLength,
                                                    length: markerLength))
            }
        }
        apply(NoteTextView.boldRegex, markerLength: 2) {
            storage.addAttribute(.font, value: boldFont, range: $0)
        }
        // .obliqueness instead of an italic font: SF Rounded has no italic face.
        apply(NoteTextView.italicRegex, markerLength: 1) {
            storage.addAttribute(.obliqueness, value: 0.18, range: $0)
        }
        apply(NoteTextView.underscoreRegex, markerLength: 1) {
            storage.addAttribute(.obliqueness, value: 0.18, range: $0)
        }
        apply(NoteTextView.strikeRegex, markerLength: 2) {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: $0)
        }
        apply(NoteTextView.highlightRegex, markerLength: 2) {
            storage.addAttribute(.backgroundColor, value: accent.withAlphaComponent(0.28), range: $0)
        }
        apply(NoteTextView.codeSpanRegex, markerLength: 1) {
            storage.addAttribute(.font, value: monoFont, range: $0)
            storage.addAttribute(.backgroundColor,
                                 value: NSColor.labelColor.withAlphaComponent(0.06), range: $0)
        }
    }

    /// ⌘B/⌘I/⌘E/… — wrap the selection (or the word at the caret) in a markdown
    /// marker; if it's already wrapped, unwrap. With nothing under the caret,
    /// inserts the pair and parks the caret between them.
    func toggleWrap(_ marker: String) {
        let ns = string as NSString
        var range = selectedRange()
        if range.length == 0 {
            let word = selectionRange(forProposedRange: range, granularity: .selectByWord)
            if !ns.substring(with: word).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                range = word
            }
        }
        let markerLength = (marker as NSString).length
        let text = ns.substring(with: range)

        if text.hasPrefix(marker), text.hasSuffix(marker),
           (text as NSString).length >= 2 * markerLength {
            let inner = (text as NSString).substring(
                from: markerLength).dropLast(marker.count)
            replaceRange(range, with: String(inner))
            setSelectedRange(NSRange(location: range.location, length: (String(inner) as NSString).length))
            return
        }
        if range.location >= markerLength, range.upperBound + markerLength <= ns.length,
           ns.substring(with: NSRange(location: range.location - markerLength, length: markerLength)) == marker,
           ns.substring(with: NSRange(location: range.upperBound, length: markerLength)) == marker {
            let outer = NSRange(location: range.location - markerLength,
                                length: range.length + 2 * markerLength)
            replaceRange(outer, with: text)
            setSelectedRange(NSRange(location: outer.location, length: range.length))
            return
        }
        replaceRange(range, with: marker + text + marker)
        setSelectedRange(NSRange(location: range.location + markerLength,
                                 length: (text as NSString).length))
    }

    func insertPlain(_ text: String, at index: Int?) {
        let length = (string as NSString).length
        let location = min(index ?? selectedRange().location, length)
        insertText(text, replacementRange: NSRange(location: location, length: 0))
    }

    func replaceRange(_ range: NSRange, with text: String) {
        if shouldChangeText(in: range, replacementString: text) {
            replaceCharacters(in: range, with: text)
            didChangeText()
        }
    }

    private static let remindTip: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d 'at' h:mm a"
        return f
    }()

    // MARK: Editing behaviors

    override func didChangeText() {
        super.didChangeText()
        applyAutoSubstitutions()
        restyle()
        needsDisplay = true
        noteDelegate?.noteTextDidChange()
        maybeAnnounceSlash()
        maybeAnnounceWiki()
        maybeEvaluateMath()
    }

    /// "240*1.18=" — the result appears right after the equals sign.
    private func maybeEvaluateMath() {
        let selection = selectedRange()
        guard selection.length == 0, selection.location > 1 else { return }
        let ns = string as NSString
        guard ns.character(at: selection.location - 1) == 0x3D /* = */ else { return }
        var lineStart = 0
        ns.getLineStart(&lineStart, end: nil, contentsEnd: nil,
                        for: NSRange(location: selection.location, length: 0))
        let allowed = Set("0123456789.,+-*/×÷() ")
        var start = selection.location - 1
        while start > lineStart, allowed.contains(Character(UnicodeScalar(ns.character(at: start - 1)) ?? " ")) {
            start -= 1
        }
        let expression = ns.substring(with: NSRange(location: start, length: selection.location - 1 - start))
            .trimmingCharacters(in: .whitespaces)
        guard expression.contains(where: \.isNumber),
              expression.contains(where: { "+-*/×÷".contains($0) }),
              let value = Calc.evaluate(expression) else { return }
        insertPlain(Calc.format(value), at: selection.location)
    }

    /// "[[" typed — offer existing note titles.
    private func maybeAnnounceWiki() {
        let selection = selectedRange()
        guard selection.length == 0, selection.location >= 2 else { return }
        let ns = string as NSString
        guard ns.character(at: selection.location - 1) == 0x5B,
              ns.character(at: selection.location - 2) == 0x5B,
              selection.location < 3 || ns.character(at: selection.location - 3) != 0x5B
        else { return }
        noteDelegate?.noteWikiTyped(at: selection.location)
    }

    /// ⌘⌫ repeatedly eats lines upward: at the start of a line it deletes the
    /// newline (joining with the previous line) instead of being a no-op.
    override func deleteToBeginningOfLine(_ sender: Any?) {
        let selection = selectedRange()
        let ns = string as NSString
        if selection.length == 0, selection.location > 0 {
            var lineStart = 0
            ns.getLineStart(&lineStart, end: nil, contentsEnd: nil,
                            for: NSRange(location: selection.location, length: 0))
            if selection.location == lineStart {
                let joinRange = NSRange(location: selection.location - 1, length: 1)
                if shouldChangeText(in: joinRange, replacementString: "") {
                    replaceCharacters(in: joinRange, with: "")
                    didChangeText()
                }
                return
            }
        }
        super.deleteToBeginningOfLine(sender)
    }

    private func maybeAnnounceSlash() {
        let selection = selectedRange()
        guard selection.length == 0, selection.location > 0 else { return }
        let ns = string as NSString
        guard ns.character(at: selection.location - 1) == 0x2F /* "/" */ else { return }
        var lineStart = 0
        ns.getLineStart(&lineStart, end: nil, contentsEnd: nil,
                        for: NSRange(location: selection.location, length: 0))
        let prefix = ns.substring(with: NSRange(location: lineStart,
                                                length: selection.location - lineStart))
        guard prefix.trimmingCharacters(in: .whitespaces) == "/" else { return }
        noteDelegate?.noteSlashTyped(slashAt: selection.location - 1)
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
        if trimmed.hasPrefix("/"), trimmed.count > 1,
           noteDelegate?.noteCommand(String(trimmed.dropFirst())) == true {
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Click a ⟦image⟧ token to view it; click a ☐/☑ glyph to toggle it.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        for (range, url) in tokenLinks where NSLocationInRange(index, range) {
            NSWorkspace.shared.open(url.resolvingSymlinksInPath())
            return
        }
        for (token, dateRange) in remindTokens where NSLocationInRange(index, token) {
            noteDelegate?.noteRemindClicked(tokenRange: token, dateRange: dateRange)
            return
        }
        for (range, title) in wikiLinks where NSLocationInRange(index, range) {
            noteDelegate?.noteOpenWiki(title)
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
                .font: bodyFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let origin = NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height)
            (placeholder as NSString).draw(at: origin, withAttributes: attributes)
        }
    }
}
