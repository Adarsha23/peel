import AppKit
import PeelKit
import ServiceManagement

struct Config: Codable {
    var toggleHotkey: String?
    var newNoteHotkey: String?
    var searchHotkey: String?
    var clipHotkey: String?

    static func load(from root: URL) -> Config {
        let url = root.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            return config
        }
        // newNote/search stay local-only (⌃⌥N / ⌃⌥F inside a sticky) unless the
        // user opts into global specs here, e.g. "ctrl+opt+n".
        let config = Config(toggleHotkey: "cmd+shift+space", newNoteHotkey: nil,
                            searchHotkey: nil, clipHotkey: "ctrl+opt+v")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) { try? data.write(to: url) }
        return config
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = NoteStore()
    let reminders = Reminders()

    private(set) var controllers: [String: StickyController] = [:]
    private var statusItem: NSStatusItem?
    private var hotkeys: [HotKey] = []
    private var watcher: DispatchSourceFileSystemObject?
    private var reconcileTimer: Timer?
    private var pollTimer: Timer?
    private var lastPollStamp = Date.distantPast
    private var lastPollCount = -1
    private lazy var search = SearchController(app: self)
    private let help = HelpController()
    private var colorRotation = 0
    private var gitTimer: Timer?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildStatusItem()

        colorRotation = store.loadAll(includeArchived: true).count
        for note in store.loadAll() {
            reminders.sync(note: note) // reschedule after reboot
            guard note.open else { continue }
            let controller = StickyController(note: note, app: self)
            controllers[note.id] = controller
            controller.show(focus: false)
        }

        let config = Config.load(from: store.root)
        if let spec = config.toggleHotkey ?? "cmd+shift+space" as String?,
           let hotkey = HotKey(spec: spec, handler: { [weak self] in self?.toggleStickies() }) {
            hotkeys.append(hotkey)
        }
        if let spec = config.newNoteHotkey,
           let hotkey = HotKey(spec: spec, handler: { [weak self] in self?.newSticky() }) {
            hotkeys.append(hotkey)
        }
        if let spec = config.searchHotkey,
           let hotkey = HotKey(spec: spec, handler: { [weak self] in self?.showSearch() }) {
            hotkeys.append(hotkey)
        }
        if let hotkey = HotKey(spec: config.clipHotkey ?? "ctrl+opt+v",
                               handler: { [weak self] in self?.clipCapture() }) {
            hotkeys.append(hotkey)
        }

        ocrCatchUp()
        gitSnapshot()
        gitTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.gitSnapshot()
        }

        startWatcher()
        reminders.activate()
        reminders.reveal = { [weak self] id in self?.reveal(id: id, focus: true) }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(remoteCommand(_:)),
            name: Notification.Name("io.barakel.peel.command"), object: nil)
    }

    @objc private func remoteCommand(_ notification: Notification) {
        switch notification.object as? String {
        case "toggle": toggleStickies()
        case "new": newSticky()
        case "search": showSearch()
        case "show-all": showAll()
        case "hide-all": hideAll()
        case "help": showHelp()
        case "clip": clipCapture()
        default: break
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controllers.values.forEach { $0.flushPendingSave() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMostRecent(focus: true) // `open` / `peel` from Terminal lands here
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Core actions

    /// The global hotkey. Cycle: nothing visible → show; visible but not editing →
    /// focus; already editing → hide everything (clear the desk).
    func toggleStickies() {
        let visible = controllers.values.filter { $0.panel.isVisible }
        if let key = NSApp.keyWindow as? StickyPanel, key.isVisible {
            _ = key
            hideAll()
        } else if let recent = visible.max(by: { $0.note.updated < $1.note.updated }) {
            recent.focusText()
        } else {
            showMostRecent(focus: true)
        }
    }

    func showMostRecent(focus: Bool) {
        if let note = store.loadAll().first {
            reveal(id: note.id, focus: focus)
        } else {
            newSticky()
        }
    }

    func reveal(id: String, focus: Bool) {
        if let controller = controllers[id] {
            controller.show(focus: focus)
            return
        }
        guard FileManager.default.fileExists(atPath: store.fileURL(for: id).path),
              let note = store.load(id: id) else { return }
        let controller = StickyController(note: note, app: self)
        controllers[id] = controller
        controller.show(focus: focus)
    }

    @discardableResult
    @objc func newSticky() -> StickyController {
        var note = Note(color: Theme.palettes[colorRotation % 6].name) // graphite stays opt-in
        colorRotation += 1
        store.save(&note)
        let controller = StickyController(note: note, app: self)
        controllers[note.id] = controller
        controller.show(focus: true)
        return controller
    }

    /// ⌃⌥V from anywhere: whatever is on the clipboard becomes a new sticky —
    /// image, files, or text — without touching the app first.
    func clipCapture() {
        let pasteboard = NSPasteboard.general
        let controller = newSticky()
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            controller.noteAttachFiles(urls, at: 0)
        } else if pasteboard.string(forType: .string) == nil,
                  let data = NoteTextView.imageData(from: pasteboard) {
            controller.noteAttachImageData(data, at: 0)
        } else if let text = pasteboard.string(forType: .string) {
            controller.appendClipboardText(text)
        }
    }

    @objc func showSearch() { search.toggle() }

    @objc func showHelp() { help.toggle() }

    @objc func showAll() {
        for note in store.loadAll() { reveal(id: note.id, focus: false) }
    }

    @objc func hideAll() {
        controllers.values.forEach { $0.hide() }
    }

    @objc func screenshotToSticky() {
        currentSticky()?.captureScreenshot()
    }

    @objc func openNotesFolder() {
        NSWorkspace.shared.open(store.root)
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        if service.status == .enabled {
            try? service.unregister()
        } else {
            try? service.register()
        }
        sender.state = service.status == .enabled ? .on : .off
    }

    /// Notes are just files — a silent git snapshot means no thought is ever lost.
    /// ponytail: full snapshot every 6h, not per-save; the debounced saves make
    /// per-change commits noisy for zero recovery value.
    private func gitSnapshot() {
        let root = store.root.path
        DispatchQueue.global(qos: .utility).async {
            let git = "/usr/bin/git"
            guard FileManager.default.fileExists(atPath: git) else { return }
            func run(_ args: [String]) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: git)
                process.arguments = ["-C", root] + args
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
            if !FileManager.default.fileExists(atPath: root + "/.git") { run(["init", "-q"]) }
            run(["add", "-A"])
            run(["commit", "-q", "-m", "peel snapshot"])
        }
    }

    /// OCR any attachment that predates the OCR feature (or arrived externally).
    private func ocrCatchUp() {
        let store = self.store
        DispatchQueue.global(qos: .utility).async {
            for note in store.loadAll(includeArchived: true) {
                for url in store.attachments(for: note.id) { OCR.index(url) }
            }
        }
    }

    func stickyWasArchived(id: String) {
        controllers.removeValue(forKey: id)
    }

    func cascadeIndex() -> Int {
        controllers.values.filter { $0.panel.isVisible }.count
    }

    private func currentSticky() -> StickyController? {
        if let key = NSApp.keyWindow as? StickyPanel, let sticky = key.sticky { return sticky }
        let visible = controllers.values.filter { $0.panel.isVisible }
        if let recent = visible.max(by: { $0.note.updated < $1.note.updated }) { return recent }
        showMostRecent(focus: false)
        return controllers.values.max { $0.note.updated < $1.note.updated }
    }

    // MARK: Directory watcher — CLI or Claude Code edits appear live

    private func startWatcher() {
        let fd = open(store.notesDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReconcile() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source

        // The dispatch source only sees directory-level events (atomic saves, new
        // files). In-place writes — echo >>, python, Claude Code — need a poll.
        // ponytail: 2s mtime sweep over one small folder; per-file FSEvents if it ever matters
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollForChanges()
        }
    }

    private func pollForChanges() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: store.notesDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var newest = Date.distantPast
        var count = 0
        for url in urls where url.pathExtension == "md" {
            count += 1
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if date > newest { newest = date }
        }
        if newest != lastPollStamp || count != lastPollCount {
            lastPollStamp = newest
            lastPollCount = count
            reconcile()
        }
    }

    private func scheduleReconcile() {
        reconcileTimer?.invalidate()
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.reconcile()
        }
    }

    private func reconcile() {
        var seen = Set<String>()
        for note in store.loadAll() {
            seen.insert(note.id)
            reminders.sync(note: note) // external edits (CLI, agents) must schedule too
            if let controller = controllers[note.id] {
                controller.externalUpdate(note)
            } else if note.open {
                let controller = StickyController(note: note, app: self)
                controllers[note.id] = controller
                controller.show(focus: false)
            }
        }
        for (id, controller) in controllers where !seen.contains(id) {
            controller.closeForRemoval()
            reminders.cancelAll(for: id)
            controllers.removeValue(forKey: id)
        }
    }

    // MARK: Menus

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "note.text",
                                     accessibilityDescription: "Peel")
        let menu = NSMenu()
        let newItem = menuItem("New Sticky", #selector(newSticky), "n")
        newItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(newItem)
        let searchItem = menuItem("Search Notes…", #selector(showSearch), "f")
        searchItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(searchItem)
        menu.addItem(.separator())
        menu.addItem(menuItem("Show All", #selector(showAll), ""))
        menu.addItem(menuItem("Hide All", #selector(hideAll), ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("Screenshot → Sticky", #selector(screenshotToSticky), ""))
        menu.addItem(menuItem("Open Notes Folder", #selector(openNotesFolder), ""))
        menu.addItem(menuItem("Keyboard Shortcuts", #selector(showHelp), ""))
        menu.addItem(.separator())
        let loginItem = menuItem("Start at Login", #selector(toggleLoginItem(_:)), "")
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Peel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    private func menuItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// Standard Edit menu so text shortcuts work on the rare occasions the app is active.
    private func buildMainMenu() {
        let main = NSMenu()
        let appEntry = NSMenuItem()
        main.addItem(appEntry)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Peel",
                                   action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appEntry.submenu = appMenu

        let editEntry = NSMenuItem()
        main.addItem(editEntry)
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editEntry.submenu = edit
        NSApp.mainMenu = main
    }

}
