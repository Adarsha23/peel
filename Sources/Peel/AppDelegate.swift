import AppKit
import PeelKit
import ServiceManagement

struct Config: Codable {
    var toggleHotkey: String?
    var newNoteHotkey: String?
    var searchHotkey: String?
    var clipHotkey: String?
    var autoDockSeconds: Double? // idle stickies tuck into the shelf; 0 disables
    var keys: [String: String]? // in-sticky shortcut overrides, see KeyMap
    var shelfEdge: String? // bottom | top | left | right

    static func load(from root: URL) -> Config {
        let url = root.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            return config
        }
        // newNote/search stay local-only (⌃⌥N / ⌃⌥F inside a sticky) unless the
        // user opts into global specs here, e.g. "ctrl+opt+n".
        let config = Config(toggleHotkey: "cmd+shift+space", newNoteHotkey: nil,
                            searchHotkey: nil, clipHotkey: "ctrl+opt+v", autoDockSeconds: 0)
        config.save(to: root)
        return config
    }

    func save(to root: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: root.appendingPathComponent("config.json"))
        }
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
    private lazy var shelf = ShelfController(app: self)
    private let reminderAlert = ReminderAlert()
    private var colorRotation = 0
    private var gitTimer: Timer?
    private var idleTimer: Timer?
    private var config = Config()
    private(set) var keyMap = KeyMap()

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

        config = Config.load(from: store.root)
        keyMap = KeyMap(overrides: config.keys)
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

        shelf.start(edge: ShelfEdge(rawValue: config.shelfEdge ?? "") ?? .bottom)
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.idleSweep()
        }
        startWatcher()
        reminders.activate()
        reminders.reveal = { [weak self] id in self?.reveal(id: id, focus: true) }
        reminders.onFire = { [weak self] noteID, text in
            guard let self else { return }
            let note = self.store.load(id: noteID)
            var title = note?.title ?? "Reminder"
            if title.hasPrefix("@remind") { title = "Reminder" } // avoid echoing the raw line
            self.reminderAlert.show(
                noteID: noteID, text: text, title: title,
                palette: Theme.palette(note?.color ?? "yellow"),
                onOpen: { [weak self] id in self?.reveal(id: id, focus: true) },
                onSnooze: { [weak self] id, body in
                    self?.reminders.snooze(noteID: id, text: body, minutes: 10)
                })
        }

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
        case "shelf": if let screen = NSScreen.main { shelf.showManually(on: screen) }
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

    func reveal(id: String, focus: Bool, from origin: NSRect? = nil) {
        if let controller = controllers[id] {
            controller.show(focus: focus, from: origin)
            return
        }
        guard FileManager.default.fileExists(atPath: store.fileURL(for: id).path),
              let note = store.load(id: id) else { return }
        let controller = StickyController(note: note, app: self)
        controllers[id] = controller
        controller.show(focus: focus, from: origin)
    }

    /// The idle life-cycle: untouched stickies go translucent so the content
    /// underneath shows through — they stay put. Auto-tucking into the shelf
    /// is opt-in (menu bar / autoDockSeconds), since ghosting already frees
    /// the screen.
    private func idleSweep() {
        let mouse = NSEvent.mouseLocation
        let dockAfter = config.autoDockSeconds ?? 0
        for controller in controllers.values {
            guard controller.panel.isVisible,
                  !controller.panel.isKeyWindow,
                  !controller.note.sunk else { continue }
            if controller.panel.frame.insetBy(dx: -24, dy: -24)
                .contains(mouse) {
                controller.touchActivity()
                controller.setGhost(false)
                continue
            }
            let idle = Date().timeIntervalSince(controller.lastActivity)
            if dockAfter > 0, idle > dockAfter {
                controller.dockToShelf()
            } else if idle > 4 {
                controller.setGhost(true)
            }
        }
    }

    @objc private func shelfEdgePicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let edge = ShelfEdge(rawValue: raw) else { return }
        config.shelfEdge = raw
        config.save(to: store.root)
        shelf.setEdge(edge)
        sender.menu?.items.forEach { $0.state = ($0 == sender) ? .on : .off }
    }

    @objc private func toggleAutoDock(_ sender: NSMenuItem) {
        let current = config.autoDockSeconds ?? 0
        config.autoDockSeconds = current > 0 ? 0 : 10
        config.save(to: store.root)
        sender.state = (config.autoDockSeconds ?? 0) > 0 ? .on : .off
    }

    @objc private func newStickyFromMenu() { newSticky() }

    @discardableResult
    func newSticky() -> StickyController { newSticky(body: "") }

    @discardableResult
    func newSticky(body: String) -> StickyController {
        var note = Note(color: Theme.palettes[colorRotation % 6].name, // graphite stays opt-in
                        body: body)
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

    // MARK: Wiki links

    func findNote(titled query: String) -> String? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let notes = store.loadAll()
        return notes.first { $0.title.lowercased() == q }?.id
            ?? notes.first { $0.title.lowercased().hasPrefix(q) }?.id
            ?? notes.first { $0.title.lowercased().contains(q) }?.id
            ?? notes.first { $0.id.hasPrefix(q) }?.id
    }

    func noteTitles() -> [(id: String, title: String)] {
        store.loadAll().map { ($0.id, $0.title) }
    }

    /// Magnetize a dragged sticky to other stickies' edges and screen edges.
    func snappedOrigin(_ origin: NSPoint, size: NSSize, excluding id: String?) -> NSPoint {
        let threshold: CGFloat = 8
        var xTargets: [CGFloat] = []
        var yTargets: [CGFloat] = []
        for controller in controllers.values
        where controller.note.id != id && controller.panel.isVisible {
            let f = controller.panel.frame
            xTargets += [f.minX, f.maxX - size.width, f.maxX, f.minX - size.width]
            yTargets += [f.minY, f.maxY - size.height, f.maxY, f.minY - size.height]
        }
        if let screen = NSScreen.screens.first(where: { NSPointInRect(origin, $0.frame) }) ?? NSScreen.main {
            let v = screen.visibleFrame
            xTargets += [v.minX, v.maxX - size.width]
            yTargets += [v.minY, v.maxY - size.height]
        }
        var snapped = origin
        if let x = xTargets.min(by: { abs($0 - origin.x) < abs($1 - origin.x) }),
           abs(x - origin.x) <= threshold { snapped.x = x }
        if let y = yTargets.min(by: { abs($0 - origin.y) < abs($1 - origin.y) }),
           abs(y - origin.y) <= threshold { snapped.y = y }
        return snapped
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
        let newItem = menuItem("New Sticky", #selector(newStickyFromMenu), "n")
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
        let edgeItem = NSMenuItem(title: "Shelf Edge", action: nil, keyEquivalent: "")
        let edgeMenu = NSMenu()
        let currentEdge = ShelfEdge(rawValue: Config.load(from: store.root).shelfEdge ?? "") ?? .bottom
        for edge in ShelfEdge.allCases {
            let item = NSMenuItem(title: edge.rawValue.capitalized,
                                  action: #selector(shelfEdgePicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = edge.rawValue
            if edge == currentEdge { item.state = .on }
            edgeMenu.addItem(item)
        }
        edgeItem.submenu = edgeMenu
        menu.addItem(edgeItem)
        let tuckItem = menuItem("Auto-tuck Idle Stickies", #selector(toggleAutoDock(_:)), "")
        tuckItem.state = (Config.load(from: store.root).autoDockSeconds ?? 0) > 0 ? .on : .off
        menu.addItem(tuckItem)
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
