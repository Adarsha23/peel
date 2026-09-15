import Foundation
import PeelKit

/// Temporary notes: an `@expire <time>` line auto-archives the note when the
/// time arrives. Good for OTPs, temp links, throwaway debug output.
/// Relative times ("@expire in 10 min") anchor to the note's last edit, so
/// they stay correct across restarts instead of resetting each launch.
final class Expiry {
    var onExpire: ((String) -> Void)?
    private var timers: [String: Timer] = [:]

    func sync(note: Note) {
        cancel(for: note.id)
        guard let date = Expiry.expiryDate(for: note) else { return }
        if date <= Date() {
            // due while the app was closed: archive on the next runloop tick
            let id = note.id
            DispatchQueue.main.async { [weak self] in self?.onExpire?(id) }
            return
        }
        let id = note.id
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            self?.timers[id] = nil
            self?.onExpire?(id)
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[id] = timer
    }

    func cancel(for noteID: String) {
        timers[noteID]?.invalidate()
        timers[noteID] = nil
    }

    /// The archive time for a note, or nil if it has no `@expire` line.
    static func expiryDate(for note: Note) -> Date? {
        for line in note.body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("@expire") else { continue }
            // anchor relative durations to the note's edit time, not now
            if let match = When.detect(in: trimmed, now: note.updated) { return match.date }
        }
        return nil
    }
}
