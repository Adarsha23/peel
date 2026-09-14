import Foundation
import UserNotifications
import PeelKit

/// Lightweight reminders: any line starting with "@remind" is scanned for a natural
/// language date ("@remind tomorrow 10am review the PR") and scheduled as a local
/// notification. Works fully offline; requires running from the installed .app
/// bundle (notification daemon needs a bundle identifier).
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
    static let isAvailable = Bundle.main.bundleIdentifier != nil
        && Bundle.main.bundlePath.hasSuffix(".app")

    var reveal: ((String) -> Void)?

    /// One detector shared with the editor, so live styling and actual
    /// scheduling always agree on what parses.
    static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// True when the user has declined notification permission — the editor
    /// surfaces this in the @remind tooltip instead of failing silently.
    private(set) static var notificationsDenied = false

    private var scheduled: [String: Set<String>] = [:] // note id -> notification ids
    private var authorizationRequested = false

    /// First future date found in a line, with its range in that line.
    static func detect(in line: String) -> (date: Date, range: NSRange)? {
        guard let detector else { return nil }
        let ns = line as NSString
        let matches = detector.matches(in: line, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            if let date = match.date, date > Date() { return (date, match.range) }
        }
        return nil
    }

    /// The custom chime lives in the app bundle; macOS reliably resolves custom
    /// notification sounds from ~/Library/Sounds, so we mirror it there once.
    static let chimeName = "peel-chime.wav"

    func activate() {
        guard Reminders.isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorizationStatus()
        installChimeIfNeeded()
    }

    private func installChimeIfNeeded() {
        guard let source = Bundle.main.url(forResource: "peel-chime", withExtension: "wav") else { return }
        let soundsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Sounds")
        let dest = soundsDir.appendingPathComponent(Reminders.chimeName)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        try? FileManager.default.createDirectory(at: soundsDir, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: source, to: dest)
    }

    private func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Reminders.notificationsDenied = settings.authorizationStatus == .denied
        }
    }

    func sync(note: Note) {
        guard Reminders.isAvailable else { return }
        refreshAuthorizationStatus() // keep the editor's denied-warning current
        var wanted: [String: (Date, String)] = [:]
        for line in note.body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("@remind") else { continue }
            guard let (date, dateRange) = Reminders.detect(in: trimmed) else { continue }
            // Notification body = the line minus the @remind token and the date phrase.
            var text = (trimmed as NSString).replacingCharacters(in: dateRange, with: " ")
            text = text.replacingOccurrences(of: "@remind", with: "")
                .trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: "—–-:,")))
            if text.isEmpty { text = note.title }
            wanted["peel.\(note.id).\(stableHash(trimmed))"] = (date, text)
        }

        let center = UNUserNotificationCenter.current()
        let previous = scheduled[note.id] ?? []
        let stale = previous.subtracting(wanted.keys)
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: Array(stale)) }
        scheduled[note.id] = Set(wanted.keys)
        guard !wanted.isEmpty else { return }

        requestAuthorizationIfNeeded()
        for (id, (date, text)) in wanted {
            let content = UNMutableNotificationContent()
            content.title = note.title
            content.body = text
            content.sound = UNNotificationSound(named: UNNotificationSoundName(Reminders.chimeName))
            content.userInfo = ["noteID": note.id]
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    /// Cancel everything scheduled for a note (it was archived or deleted).
    func cancelAll(for noteID: String) {
        guard Reminders.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let prefix = "peel.\(noteID)."
        scheduled[noteID] = nil
        center.getPendingNotificationRequests { requests in
            let stale = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
                self?.refreshAuthorizationStatus()
            }
    }

    private func stableHash(_ s: String) -> String {
        var hash: UInt64 = 5381
        for byte in s.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return String(hash, radix: 36)
    }

    // MARK: UNUserNotificationCenterDelegate
    // Completion-handler signatures, deliberately: if the async variants aren't
    // bridged and invoked, macOS treats an active app's notification as
    // "suppress the banner, file it quietly" — reminders vanish into
    // Notification Center. These forms are always called.

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let noteID = response.notification.request.content.userInfo["noteID"] as? String {
            DispatchQueue.main.async { [weak self] in self?.reveal?(noteID) }
        }
        completionHandler()
    }
}
