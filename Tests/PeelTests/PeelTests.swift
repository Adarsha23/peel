import Testing
import Foundation
@testable import PeelKit

@Suite struct NoteTests {
    @Test func serializationRoundTrip() {
        var note = Note(color: "lavender", x: 120, y: 340, width: 300, height: 220,
                        body: "# Ideas\n\n- [ ] ship peel\n- [x] pick a name\n\nplain line")
        note.open = false
        note.sunk = true
        let parsed = Note.parse(fileContents: note.serialize(), fallbackID: "fallback")
        #expect(parsed.id == note.id)
        #expect(parsed.color == "lavender")
        #expect(parsed.x == 120)
        #expect(parsed.y == 340)
        #expect(parsed.open == false)
        #expect(parsed.sunk == true)
        #expect(parsed.body == note.body)
    }

    @Test func malformedFileBecomesBodyOnlyNote() {
        let note = Note.parse(fileContents: "just some text\nno frontmatter", fallbackID: "abc")
        #expect(note.id == "abc")
        #expect(note.body == "just some text\nno frontmatter")
    }

    @Test func unclosedFrontmatterIsTreatedAsBody() {
        let text = "---\nid: broken\nnever closed"
        #expect(Note.parse(fileContents: text, fallbackID: "abc").body == text)
    }

    @Test func titleSkipsMarkersAndBlankLines() {
        #expect(Note(body: "\n\n- [ ] fix the bug\nmore").title == "fix the bug")
        #expect(Note(body: "# Heading").title == "Heading")
        #expect(Note(body: "").title == "Untitled")
    }

    @Test func todoCounts() {
        let note = Note(body: "- [ ] one\n- [x] two\n- [X] three\n- plain bullet")
        #expect(note.todoCounts.open == 1)
        #expect(note.todoCounts.done == 2)
    }

    @Test func idFormat() {
        let id = Note.makeID()
        #expect(id.count == 20) // yyyyMMdd-HHmmss-xxxx
        #expect(!id.contains(" "))
    }
}

@Suite struct MarkupTests {
    @Test func displayMapping() {
        let md = "- [ ] task\n- [x] done\n- bullet\n* star bullet\nplain"
        #expect(Markup.display(fromMarkdown: md) == "☐ task\n☑ done\n• bullet\n• star bullet\nplain")
    }

    @Test func roundTrip() {
        let md = "# Title\n\n- [ ] a\n  - [x] nested\n- bullet\n\n1. numbered\nplain"
        let display = Markup.display(fromMarkdown: md)
        #expect(Markup.markdown(fromDisplay: display) == md)
    }

    @Test func codeFencesAreLeftAlone() {
        let md = "```\n- [ ] not a todo\n- not a bullet\n```\n- [ ] real todo"
        let display = Markup.display(fromMarkdown: md)
        #expect(display.contains("- [ ] not a todo"))
        #expect(display.hasSuffix("☐ real todo"))
        #expect(Markup.markdown(fromDisplay: display) == md)
    }

    @Test func bareGlyphsSerialize() {
        #expect(Markup.markdown(fromDisplay: "☐") == "- [ ] ")
        #expect(Markup.markdown(fromDisplay: "☑") == "- [x] ")
    }

    @Test func indentPreserved() {
        #expect(Markup.display(fromMarkdown: "  - [ ] indented") == "  ☐ indented")
        #expect(Markup.markdown(fromDisplay: "  ☐ indented") == "  - [ ] indented")
    }

    @Test func imageTokenRoundTrip() {
        let md = "notes before\n![image-1.png](../attachments/abc-123/image-1.png) between text\n- [ ] after"
        let display = Markup.display(fromMarkdown: md, noteID: "abc-123")
        #expect(display.contains("⟦image-1.png⟧ between text"))
        #expect(!display.contains("!["))
        #expect(Markup.markdown(fromDisplay: display, noteID: "abc-123") == md)
    }

    @Test func multipleInlineTokensOnOneLine() {
        let display = "first ⟦image-1.png⟧ then ⟦screenshot-2.png⟧ done"
        let md = Markup.markdown(fromDisplay: display, noteID: "n1")
        #expect(md == "first ![image-1.png](../attachments/n1/image-1.png) then ![screenshot-2.png](../attachments/n1/screenshot-2.png) done")
        #expect(Markup.display(fromMarkdown: md, noteID: "n1") == display)
    }

    @Test func foreignImagePathsStayRaw() {
        let md = "![diagram](https://example.com/x.png)\n![other](../attachments/OTHER-note/y.png)"
        #expect(Markup.display(fromMarkdown: md, noteID: "abc") == md)
    }

    @Test func tokensWithoutNoteIDStayLiteral() {
        let display = "⟦image-1.png⟧"
        #expect(Markup.markdown(fromDisplay: display) == display)
    }
}

final class StoreTests {
    let tmp: URL
    let store: NoteStore

    init() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("peel-tests-\(UUID().uuidString)")
        store = NoteStore(root: tmp)
    }

    deinit { try? FileManager.default.removeItem(at: tmp) }

    @Test func saveAndLoad() {
        var note = Note(body: "hello world")
        store.save(&note)
        let loaded = store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == note.id)
        #expect(loaded[0].body == "hello world")
    }

    @Test func saveTouchUpdatesTimestampOnlyWhenAsked() {
        var note = Note(updated: Date(timeIntervalSince1970: 1000))
        store.save(&note, touch: false)
        #expect(note.updated == Date(timeIntervalSince1970: 1000))
        store.save(&note, touch: true)
        #expect(note.updated.timeIntervalSince1970 > 1000)
    }

    @Test func archiveMovesFileAndSurvives() {
        var note = Note(body: "keep me")
        store.save(&note)
        store.archive(id: note.id)
        #expect(store.loadAll().isEmpty)
        let archived = store.loadAll(includeArchived: true)
        #expect(archived.count == 1)
        #expect(archived[0].body == "keep me")
        #expect(archived[0].open == false)
    }

    @Test func searchBodyAndAttachmentNames() {
        var a = Note(body: "authentication middleware bug")
        var b = Note(body: "grocery list")
        store.save(&a)
        store.save(&b)
        store.attach(data: Data("x".utf8), named: "architecture-diagram.png", to: b.id)

        #expect(store.search("authentication").map(\.id) == [a.id])
        #expect(store.search("architecture").map(\.id) == [b.id])
        #expect(store.search("authentication grocery").isEmpty) // AND semantics
    }

    @Test func searchFindsOCRSidecarText() throws {
        var note = Note(body: "empty note")
        store.save(&note)
        let image = store.attachmentsDir(for: note.id, create: true)
            .appendingPathComponent("shot.png")
        try Data("fake".utf8).write(to: image)
        let sidecar = OCR.sidecarURL(for: image)
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "NSPanel error dialog contents".write(to: sidecar, atomically: true, encoding: .utf8)

        #expect(store.search("nspanel dialog").map(\.id) == [note.id])
        // hidden .ocr folder must never appear as an attachment
        #expect(store.attachments(for: note.id).map(\.lastPathComponent) == ["shot.png"])
    }

    @Test func resolveByPrefix() {
        var note = Note(body: "findable")
        store.save(&note)
        #expect(store.resolve(idPrefix: String(note.id.prefix(8)))?.id == note.id)
        #expect(store.resolve(idPrefix: "zzz") == nil)
    }

    @Test func attachDeduplicatesNames() {
        let note = Note()
        let u1 = store.attach(data: Data("a".utf8), named: "shot.png", to: note.id)
        let u2 = store.attach(data: Data("b".utf8), named: "shot.png", to: note.id)
        #expect(u1?.lastPathComponent == "shot.png")
        #expect(u2?.lastPathComponent == "shot-2.png")
    }

    @Test func corruptFileDoesNotBreakLoadAll() {
        var good = Note(body: "fine")
        store.save(&good)
        try? Data([0xFF, 0xFE, 0x00, 0x01]).write(to: store.notesDir.appendingPathComponent("garbage.md"))
        #expect(store.loadAll().contains { $0.id == good.id })
    }
}

final class CLITests {
    let tmp: URL
    let store: NoteStore

    init() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("peel-cli-tests-\(UUID().uuidString)")
        store = NoteStore(root: tmp)
    }

    deinit { try? FileManager.default.removeItem(at: tmp) }

    @Test func newListShowArchive() {
        #expect(CLI.run(["new", "buy oat milk"], store: store) == 0)
        let notes = store.loadAll()
        #expect(notes.count == 1)
        #expect(notes[0].body == "buy oat milk")

        #expect(CLI.run(["list"], store: store) == 0)
        #expect(CLI.run(["show", notes[0].id], store: store) == 0)
        #expect(CLI.run(["archive", notes[0].id], store: store) == 0)
        #expect(store.loadAll().isEmpty)
        #expect(store.loadAll(includeArchived: true).count == 1)
    }

    @Test func unknownCommandFails() {
        #expect(CLI.run(["frobnicate"], store: store) == 1)
    }

    @Test func showMissingNoteFails() {
        #expect(CLI.run(["show", "nope"], store: store) == 1)
    }
}
