import Foundation

/// Plain-file persistence. Everything lives under one transparent directory:
///   notes/<id>.md          the note (frontmatter + markdown)
///   attachments/<id>/      dropped/pasted files for that note
///   archive/<id>.md        archived notes (never silently deleted)
public final class NoteStore {
    public let root: URL

    public var notesDir: URL { root.appendingPathComponent("notes") }
    public var archiveDir: URL { root.appendingPathComponent("archive") }
    public var attachmentsRoot: URL { root.appendingPathComponent("attachments") }

    public static func defaultRoot() -> URL {
        if let env = ProcessInfo.processInfo.environment["PEEL_DATA_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Peel")
    }

    public init(root: URL = NoteStore.defaultRoot()) {
        self.root = root
        for dir in [notesDir, archiveDir, attachmentsRoot] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public func fileURL(for id: String) -> URL { notesDir.appendingPathComponent(id + ".md") }

    public func loadAll(includeArchived: Bool = false) -> [Note] {
        var notes = load(from: notesDir)
        if includeArchived { notes += load(from: archiveDir) }
        return notes.sorted { $0.updated > $1.updated }
    }

    public func load(id: String) -> Note? {
        loadNote(at: fileURL(for: id)) ?? loadNote(at: archiveDir.appendingPathComponent(id + ".md"))
    }

    private func load(from dir: URL) -> [Note] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.compactMap(loadNote(at:))
    }

    private func loadNote(at url: URL) -> Note? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var note = Note.parse(fileContents: text, fallbackID: url.deletingPathExtension().lastPathComponent)
        note.id = url.deletingPathExtension().lastPathComponent // filename is canonical
        return note
    }

    @discardableResult
    public func save(_ note: inout Note, touch: Bool = true) -> URL {
        if touch { note.updated = Date() }
        let url = fileURL(for: note.id)
        try? note.serialize().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public func archive(id: String) {
        guard var note = load(id: id) else { return }
        note.open = false
        save(&note, touch: false)
        try? FileManager.default.moveItem(at: fileURL(for: id),
                                          to: archiveDir.appendingPathComponent(id + ".md"))
    }

    public func resolve(idPrefix: String) -> Note? {
        let all = loadAll(includeArchived: true)
        return all.first { $0.id == idPrefix } ?? all.first { $0.id.hasPrefix(idPrefix) }
    }

    // MARK: Attachments

    public func attachmentsDir(for id: String, create: Bool = false) -> URL {
        let dir = attachmentsRoot.appendingPathComponent(id)
        if create { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        return dir
    }

    public func attachments(for id: String) -> [URL] {
        let dir = attachmentsDir(for: id)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return da < db
        }
    }

    /// Copies a file into the note's attachment folder; symlinks anything over 100 MB
    /// instead of duplicating it. Returns the stored URL.
    @discardableResult
    public func attach(fileAt source: URL, to id: String) -> URL? {
        let dir = attachmentsDir(for: id, create: true)
        var dest = dir.appendingPathComponent(source.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            let base = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            dest = dir.appendingPathComponent(name)
            counter += 1
        }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        do {
            if size > 100 * 1024 * 1024 {
                try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: source)
            } else {
                try FileManager.default.copyItem(at: source, to: dest)
            }
            OCR.index(dest)
            return dest
        } catch {
            return nil
        }
    }

    @discardableResult
    public func attach(data: Data, named name: String, to id: String) -> URL? {
        let dir = attachmentsDir(for: id, create: true)
        var dest = dir.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)")
            counter += 1
        }
        do { try data.write(to: dest) } catch { return nil }
        OCR.index(dest)
        return dest
    }

    // MARK: Search

    /// Case-insensitive AND-token search over body, id, and attachment filenames.
    public func search(_ query: String, in candidates: [Note]? = nil) -> [Note] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let notes = candidates ?? loadAll()
        return notes.filter { note in
            var hay = note.body.lowercased() + " " + note.id.lowercased()
            for url in attachments(for: note.id) {
                hay += " " + url.lastPathComponent.lowercased()
                if let ocr = OCR.text(for: url) { hay += " " + ocr.lowercased() } // screenshots are searchable
            }
            return tokens.allSatisfy { hay.contains($0) }
        }
    }
}
