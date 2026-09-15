import Testing
import Foundation
@testable import PeelKit

@Suite struct NoteTests {
    @Test func serializationRoundTrip() {
        var note = Note(color: "lavender", x: 120, y: 340, width: 300, height: 220,
                        body: "# Ideas\n\n- [ ] ship peel\n- [x] pick a name\n\nplain line")
        note.open = false
        note.sunk = true
        note.fontSize = 16
        note.locked = true
        note.userSized = true
        let parsed = Note.parse(fileContents: note.serialize(), fallbackID: "fallback")
        #expect(parsed.fontSize == 16)
        #expect(parsed.locked == true)
        #expect(parsed.userSized == true)
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

@Suite struct SmartCaptureTests {
    @Test func loneURLStaysBare() {
        #expect(SmartCapture.format("https://github.com/Adarsha23/peel") == "https://github.com/Adarsha23/peel")
        #expect(SmartCapture.isSingleURL("https://a.com/b?c=d"))
        #expect(!SmartCapture.isSingleURL("see https://a.com for more"))
    }

    @Test func codeGetsFenced() {
        let js = "function add(a, b) {\n  return a + b;\n}"
        #expect(SmartCapture.format(js) == "```\n" + js + "\n```")
        #expect(SmartCapture.looksLikeCodeOrError("const x = () => {\n  return 1;\n}"))
        #expect(SmartCapture.looksLikeCodeOrError("#include <stdio.h>\nint main() {}"))
    }

    @Test func errorsGetFenced() {
        #expect(SmartCapture.looksLikeCodeOrError("TypeError: Cannot read properties of undefined"))
        #expect(SmartCapture.looksLikeCodeOrError("Traceback (most recent call last)\n  File x"))
    }

    @Test func proseIsLeftAlone() {
        #expect(SmartCapture.format("buy oat milk and coffee") == "buy oat milk and coffee")
        #expect(!SmartCapture.looksLikeCodeOrError("Remember: call the bank tomorrow"))
        let list = "milk\neggs\nbread"
        #expect(SmartCapture.format(list) == list)
    }

    @Test func alreadyFencedIsNotDoubleFenced() {
        let fenced = "```\ncode\n```"
        #expect(SmartCapture.format(fenced) == fenced)
    }
}

@Suite struct CalcTests {
    @Test func arithmetic() {
        #expect(Calc.evaluate("240*1.18") == 283.2)
        #expect(Calc.evaluate("5*12") == 60)
        #expect(Calc.evaluate("2*(3+4)") == 14)
        #expect(Calc.evaluate("10/4") == 2.5)
        #expect(Calc.evaluate("-5+3") == -2)
        #expect(Calc.evaluate("1,000*2") == 2000)
        #expect(Calc.evaluate("6×7") == 42)
        #expect(Calc.evaluate("10÷4") == 2.5)
    }

    @Test func garbageIsRejectedNotCrashed() {
        #expect(Calc.evaluate("10/0") == nil)
        #expect(Calc.evaluate("abc") == nil)
        #expect(Calc.evaluate("5*") == nil)
        #expect(Calc.evaluate("(3+4") == nil)
        #expect(Calc.evaluate("") == nil)
        #expect(Calc.evaluate("5..2*3") == nil)
    }

    @Test func humanFormatting() {
        #expect(Calc.format(60) == "60")
        #expect(Calc.format(283.2) == "283.2")
        #expect(Calc.format(2.5) == "2.5")
        #expect(Calc.format(1.0 / 3.0) == "0.333333")
    }
}

@Suite struct WhenTests {
    // Anchor: Monday Sep 14 2026, 12:00 local time.
    let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 12))!

    func fire(_ line: String) -> When.Match? {
        When.detect(in: line, now: noon)
    }

    @Test func relativePhrases() {
        #expect(fire("in 20 min do the thing")?.date == noon.addingTimeInterval(20 * 60))
        #expect(fire("in 2 hours")?.date == noon.addingTimeInterval(2 * 3600))
        #expect(fire("in 3 days")?.date == noon.addingTimeInterval(3 * 86400))
        #expect(fire("5m stretch")?.date == noon.addingTimeInterval(5 * 60))
        #expect(fire("2h nap")?.date == noon.addingTimeInterval(2 * 3600))
        #expect(fire("in 1 week")?.date == noon.addingTimeInterval(7 * 86400))
        #expect(fire("in 20 min")?.repeats == When.Repeat.none)
    }

    @Test func recurringDaily() throws {
        let match = try #require(fire("every day at 3pm water plants"))
        #expect(match.repeats == .daily)
        let c = Calendar.current.dateComponents([.day, .hour, .minute], from: match.date)
        #expect(c.hour == 15 && c.minute == 0 && c.day == 14) // today, 3pm is still ahead of noon
    }

    @Test func recurringDailyRollsToTomorrow() throws {
        let match = try #require(fire("every day at 9am standup"))
        let c = Calendar.current.dateComponents([.day, .hour], from: match.date)
        #expect(c.hour == 9 && c.day == 15) // 9am already passed at noon
    }

    @Test func recurringWeekday() throws {
        let match = try #require(fire("every weekday 9am standup"))
        #expect(match.repeats == .weekdays)
        let c = Calendar.current.dateComponents([.weekday, .hour], from: match.date)
        #expect(c.hour == 9)
        #expect([2, 3, 4, 5, 6].contains(c.weekday!))
    }

    @Test func recurringWeekend() throws {
        let match = try #require(fire("every weekend at 10am ride"))
        #expect(match.repeats == .weekends)
        let c = Calendar.current.dateComponents([.weekday, .hour], from: match.date)
        #expect(c.hour == 10)
        #expect([1, 7].contains(c.weekday!))
    }

    @Test func recurringNamedDay() throws {
        let match = try #require(fire("every monday 9:30 review"))
        #expect(match.repeats == .weekly(weekday: 2))
        let c = Calendar.current.dateComponents([.weekday, .hour, .minute], from: match.date)
        #expect(c.weekday == 2 && c.hour == 9 && c.minute == 30)
    }

    @Test func smallHoursWithoutAmPmMeanAfternoon() throws {
        let match = try #require(fire("every day at 3 water plants"))
        #expect(Calendar.current.component(.hour, from: match.date) == 15)
        let nine = try #require(fire("every day at 9"))
        #expect(Calendar.current.component(.hour, from: nine.date) == 9)
    }

    @Test func absoluteFallback() throws {
        let match = try #require(fire("Sep 20, 2:30 PM check the oven"))
        #expect(match.repeats == When.Repeat.none)
        let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: match.date)
        #expect(c.month == 9 && c.day == 20 && c.hour == 14 && c.minute == 30)
    }

    @Test func garbageParsesToNothing() {
        #expect(fire("someday maybe") == nil)
        #expect(fire("every blue moon") == nil)
        #expect(fire("") == nil)
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
