import AppKit
import Foundation

/// Watches the system clipboard for screenshots and — when a browser is
/// frontmost — quietly grabs the active tab's URL. The mapping is stored for
/// up to 30 minutes so you can screenshot a page, finish reading, then paste
/// the shot into a Peel note and find the URL already attached.
/// No network access, no background process. Just polling changeCount.
final class ClipboardWatcher {
    /// Called with (imageData, url?) when a screenshot arrives.
    var onCapture: ((Data, String?) -> Void)?

    private var lastChangeCount = 0
    private var timer: Timer?
    // hash(first 8KB of image) → (url, expiry). Bounded to 30 entries.
    private var cache: [Int: (url: String, expires: Date)] = [:]

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func url(for imageData: Data) -> String? {
        let key = hashKey(imageData)
        guard let entry = cache[key], entry.expires > Date() else { return nil }
        return entry.url
    }

    // MARK: private

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let data = ClipboardWatcher.imageData(from: pb) else { return }
        let url = frontBrowserURL()
        let key = hashKey(data)
        if let url {
            evictExpired()
            cache[key] = (url, Date().addingTimeInterval(30 * 60))
        }
        onCapture?(data, url)
    }

    private func evictExpired() {
        let now = Date()
        cache = cache.filter { $0.value.expires > now }
        if cache.count > 30 {
            // drop oldest
            let sorted = cache.sorted { $0.value.expires < $1.value.expires }
            for entry in sorted.prefix(cache.count - 30) { cache[entry.key] = nil }
        }
    }

    private func hashKey(_ data: Data) -> Int {
        var h = Hasher()
        h.combine(data.prefix(8192))
        return h.finalize()
    }

    static func imageData(from pb: NSPasteboard) -> Data? {
        if let d = pb.data(forType: .png) { return d }
        if let d = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: d) {
            return rep.representation(using: .png, properties: [:])
        }
        if let img = NSImage(pasteboard: pb),
           let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    /// Returns the active tab URL from the frontmost browser via AppleScript.
    /// Returns nil silently if the front app isn't a supported browser or
    /// if the user hasn't granted Automation permission yet.
    private func frontBrowserURL() -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let name = frontApp.localizedName else { return nil }
        let script: String
        switch true {
        case name.hasPrefix("Google Chrome"), name.hasPrefix("Chromium"),
             name.hasPrefix("Brave Browser"), name.hasPrefix("Microsoft Edge"),
             name.hasPrefix("Arc"), name.hasPrefix("Opera"):
            script = "tell application \"\(name)\" to URL of active tab of front window"
        case name.hasPrefix("Safari"):
            script = "tell application \"\(name)\" to URL of current tab of front window"
        default:
            return nil
        }
        var err: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&err) else { return nil }
        return result.stringValue
    }
}
