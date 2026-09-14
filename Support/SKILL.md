---
name: peel-notes
description: Read, search, and write the user's Peel sticky notes — floating markdown notes with screenshot/file attachments, todos, and reminders. Use whenever the user references their sticky notes, notes from today, screenshots they posted or dropped into a note, feedback they wrote down about a task, or asks to leave a note or reminder on their screen.
---

# Peel sticky notes

Peel is the user's local floating sticky-note app (repo: `~/Projects/Peel`).
Every note is a plain markdown file — no database, no API. The user routinely
drops screenshots into notes and writes task feedback there, so "the screenshot
I posted" or "my notes on X" almost always means a Peel note.

Data root: `~/Library/Application Support/Peel/`

- `notes/<id>.md` — active notes: flat frontmatter (`id`, `color`, `x/y/width/height`, `open`, `sunk`, `created`, `updated`) + markdown body
- `attachments/<id>/` — that note's images and files
- `archive/<id>.md` — archived notes, never deleted

## Reading (start here)

- `peel today` — full markdown of every note touched today; best first stop for "my recent notes/feedback"
- `peel search <query>` — full-text across bodies, attachment filenames, ids; includes archived
- `peel list` — overview (id, age, todo counts, title)
- `peel show <id-prefix>` — one note plus its attachment list
- Reading/grepping the files directly is equally fine

## Screenshots & attachments

Inline image references in a body look like:

    ![image-1.png](../attachments/<note-id>/image-1.png)

Resolve them relative to the `notes/` directory — i.e.
`~/Library/Application Support/Peel/attachments/<note-id>/image-1.png` — and
Read that file to view the screenshot (Read renders images).

**Order matters**: inline references sit exactly where the user placed them
between sentences, so process images in body order (top to bottom), not by
filename or directory listing — the surrounding text is each screenshot's
context. Files in `attachments/<id>/` without an inline reference are still
attachments of that note (its strip shows them); their order is creation time.

### OCR sidecars

Every image attachment gets on-device OCR; the extracted text lives at
`attachments/<id>/.ocr/<filename>.txt`. `peel search` already includes it, and
grepping the `.ocr` folders is the fast way to find a screenshot by its
contents without opening images.

## Body conventions

- `- [ ] task` / `- [x] done` — todo state lives in the markdown; editing it updates the sticky
- `@remind <natural time> <message>` — schedules a macOS notification when the app saves the note

## Writing back (the running app live-reloads files within ~2s)

- `peel new "text"` — creates a note and pops it onto the user's screen; good for leaving a summary or result the user should see
- Editing a note file directly is safe while the app runs; keep the frontmatter intact and don't rewrite a note the user is actively typing in
- `peel ui <toggle|new|search|show-all|hide-all|help>` — remote-control the running app
- `peel archive <id>` to tidy up; never `rm` note files
- `peel doctor` — diagnose reminders / notification permission
