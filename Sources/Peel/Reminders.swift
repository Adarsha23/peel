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

    /// True when the user has declined notification permission — the editor
    /// surfaces this in the @remind tooltip instead of failing silently.
    private(set) static var notificationsDenied = false

    private var scheduled: [String: Set<String>] = [:] // note id -> notification ids
    private var authorizationRequested = false

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

    /// Native alarm: fired by the running app itself — a floating Peel card +
    /// chime, independent of the macOS notification pipeline. (noteID, text)
    var onFire: ((String, String) -> Void)?

    private var timers: [String: Timer] = [:]

    func sync(note: Note) {
        var wanted: [String: (match: When.Match, text: String, line: String)] = [:]
        for line in note.body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("@remind") else { continue }
            guard let match = When.detect(in: trimmed) else { continue }
            // Reminder text = the line minus the @remind token and the time phrase.
            var text = (trimmed as NSString).replacingCharacters(in: match.range, with: " ")
            text = text.replacingOccurrences(of: "@remind", with: "")
                .trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: "-–-:,")))
            if text.isEmpty { text = note.title }
            wanted["peel.\(note.id).\(stableHash(trimmed))"] = (match, text, trimmed)
        }

        // The primary path: in-app timers. Works regardless of notification
        // permission, alert styles, Focus modes, or signing identity.
        // Recurring reminders re-arm themselves after each fire.
        let prefix = "peel.\(note.id)."
        for (id, timer) in timers where id.hasPrefix(prefix) && wanted[id] == nil {
            timer.invalidate()
            timers[id] = nil
        }
        for (id, item) in wanted where timers[id] == nil {
            scheduleTimer(id: id, noteID: note.id, fireAt: item.match.date,
                          text: item.text, line: item.line)
        }

        // Secondary: system notifications, so reminders survive the app being quit.
        guard Reminders.isAvailable else { return }
        refreshAuthorizationStatus() // keep the editor's denied-warning current
        let center = UNUserNotificationCenter.current()
        var systemIDs = Set<String>()
        var requests: [UNNotificationRequest] = []
        for (id, item) in wanted {
            let content = UNMutableNotificationContent()
            content.title = note.title
            content.body = item.text
            content.sound = UNNotificationSound(named: UNNotificationSoundName(Reminders.chimeName))
            content.userInfo = ["noteID": note.id]
            let clock = Calendar.current.dateComponents([.hour, .minute], from: item.match.date)
            switch item.match.repeats {
            case .none:
                let full = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: item.match.date)
                requests.append(UNNotificationRequest(
                    identifier: id, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: full, repeats: false)))
                systemIDs.insert(id)
            case .daily:
                requests.append(UNNotificationRequest(
                    identifier: id, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: clock, repeats: true)))
                systemIDs.insert(id)
            case .weekdays, .weekends, .weekly:
                // one repeating request per firing day
                for day in item.match.repeats.firingWeekdays {
                    var byDay = clock
                    byDay.weekday = day
                    let dayID = "\(id).d\(day)"
                    requests.append(UNNotificationRequest(
                        identifier: dayID, content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: byDay, repeats: true)))
                    systemIDs.insert(dayID)
                }
            }
        }
        let stale = (scheduled[note.id] ?? []).subtracting(systemIDs)
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: Array(stale)) }
        scheduled[note.id] = systemIDs
        guard !requests.isEmpty else { return }
        requestAuthorizationIfNeeded()
        requests.forEach { center.add($0) }
    }

    private func scheduleTimer(id: String, noteID: String, fireAt: Date,
                               text: String, line: String) {
        let timer = Timer(fire: fireAt, interval: 0, repeats: false) { [weak self] _ in
            self?.fire(id: id, noteID: noteID, text: text, line: line)
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[id] = timer
    }

    private func fire(id: String, noteID: String, text: String, line: String) {
        timers[id] = nil
        if let next = When.detect(in: line), next.repeats != .none {
            // recurring: arm the next occurrence
            scheduleTimer(id: id, noteID: noteID, fireAt: next.date, text: text, line: line)
        } else if Reminders.isAvailable {
            // one-shot, the app is alive and presenting this itself: no system double
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        }
        onFire?(noteID, text)
    }

    /// Snooze: re-fire the same reminder a few minutes from now (app-side only).
    func snooze(noteID: String, text: String, minutes: Double) {
        let id = "peel.\(noteID).snooze.\(stableHash(text))"
        timers[id]?.invalidate()
        scheduleTimer(id: id, noteID: noteID,
                      fireAt: Date().addingTimeInterval(minutes * 60),
                      text: text, line: "")
    }

    /// Cancel everything scheduled for a note (it was archived or deleted).
    func cancelAll(for noteID: String) {
        let prefix = "peel.\(noteID)."
        for (id, timer) in timers where id.hasPrefix(prefix) {
            timer.invalidate()
            timers[id] = nil
        }
        guard Reminders.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
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
