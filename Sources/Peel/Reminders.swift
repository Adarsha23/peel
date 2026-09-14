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

    private let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private var scheduled: [String: Set<String>] = [:] // note id -> notification ids
    private var authorizationRequested = false

    func activate() {
        guard Reminders.isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func sync(note: Note) {
        guard Reminders.isAvailable, let detector else { return }
        var wanted: [String: (Date, String)] = [:]
        for line in note.body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("@remind") else { continue }
            let text = String(trimmed.dropFirst("@remind".count)).trimmingCharacters(in: .whitespaces)
            let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            guard let date = matches.compactMap(\.date).first(where: { $0 > Date() }) else { continue }
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
            content.sound = .default
            content.userInfo = ["noteID": note.id]
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func stableHash(_ s: String) -> String {
        var hash: UInt64 = 5381
        for byte in s.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return String(hash, radix: 36)
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if let noteID = response.notification.request.content.userInfo["noteID"] as? String {
            await MainActor.run { reveal?(noteID) }
        }
    }
}
