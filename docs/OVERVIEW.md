# Peel, product overview

## What it is

Peel is a macOS sticky-note app for people who think in fragments and don't
want a note-taking app to be a whole event. Press a key, a note appears over
whatever you're doing, you type, you move on. It's native AppKit, one ~600 KB
binary, no cloud, no account, and your notes are plain markdown files on disk.

## The problems it solves

**"I had a thought and by the time the app opened it was gone."**
Every other capture flow has friction: unlock the app, wait for it, find the
right note, click into it. Peel is one global shortcut to a focused, blinking
cursor. Sub-second, every time.

**"My notes app pauses my video / steals my focus."**
This is the one nobody else gets right. Peel's window is a non-activating
panel: it takes your keystrokes when you click it and hands them straight back
when you leave. The fullscreen video underneath keeps playing, the app you're
in never loses focus, your menu bar never switches. You can take notes on a
video without touching the video.

**"I'm reading something and the note is in the way."**
Leave a sticky alone and it fades translucent and shrinks to a thin bar, so
the article underneath stays readable. Click it to bring it back. Or lock it
opaque if you want it to stay put.

**"I pay a subscription for features that should be free."**
Overlay, reminders, search, formatting, the works, all free and local. The
whole app is smaller than a single web-app JavaScript bundle.

**"My reminders never actually reach me."**
Peel fires its own reminder card with a chime. It ignores Do Not Disturb,
shows up over fullscreen, and waits until you deal with it. A reminder that
fires while you're at lunch is still there when you're back.

**"My notes are trapped in some app's database."**
They're markdown files in one transparent folder, auto-committed to a local
git repo. Any editor opens them, Claude Code reads and writes them, and they'll
outlive the app.

**"I take notes full of screenshots and can never find them again."**
Every image you paste is OCR'd on-device, so search finds the text inside your
screenshots, not just their filenames.

## Features

**Capture**
- Global hotkey summons the latest note, focused and ready (`⌘⇧Space`)
- Clipboard capture: `⌃⌥V` turns whatever you copied (text, image, files) into a note
- `peel new "thought"` from the terminal pops a note on screen
- Notes open minimal, one line tall, and grow as you type
- Autosaves ~400 ms after you stop typing. No save button, survives crashes

**The overlay**
- Floats over fullscreen video without pausing it or stealing focus
- Visible on every Space, remembers position and size per monitor
- `⌃⌥B` parks a note behind your windows and brings it back
- Idle notes fade translucent and collapse to a header bar; click to restore
- `⌃⌥L` / `/lock` pins a note opaque so it never fades
- Drag notes and their edges snap to each other and the screen

**The shelf**
- Push the cursor to a screen edge for a row of note tabs; click to open
- Pick the edge (bottom, top, left, right) in the menu bar
- Hover a tab for a browser-style close, or close all at once

**Writing**
- Live markdown: `**bold**` `*italic*` `` `code` `` `~~strike~~` `==highlight==`, plain text on disk
- Todos with `[]` + space, click the box or `⌘↩` to check; lists continue on Enter
- Inline calculator: type `240*1.18=` and the answer appears
- `[[note links]]` jump between stickies, with title autocomplete
- Per-note text zoom and seven muted paper colors
- A `/` command menu, and text utilities: `/count` `/trim` `/lower` `/upper`

**Images and files**
- Paste or drop an image; it's saved locally and referenced inline where your cursor was
- `⌃⌥S` screenshots straight into the note
- Every image is OCR'd on-device, so search reads the text inside it
- Files become chips: click to open, reveal, copy path, or trash

**Reminders**
- Natural language: `in 20 min`, `tomorrow 9am`, `every weekday at 9:30`
- Recurring reminders re-arm themselves
- Live feedback while typing; a picker menu if you'd rather choose
- Fires Peel's own card (chime, snooze) that ignores Do Not Disturb and waits for you

**Find and keep**
- Spotlight-style search over note text, filenames, and OCR'd screenshots (`⌃⌥F`)
- Archive instead of delete, attachments trash instead of vanish
- Auto-committed local git history of every note
- Move the whole data folder with `PEEL_DATA_DIR` (point it at iCloud for sync)

**Built for keyboards and for Claude Code**
- Every shortcut and the shelf edge are remappable in `config.json`
- A bundled skill teaches Claude Code where notes live and how to read your screenshots

## What it deliberately isn't

No accounts, no sync service, no teams, no rich-text editor, no plugin
marketplace, no AI features bolted on. Restraint is the point: every
competitor that added those became the thing people were trying to escape.

## Permissions

None to run. Notifications are optional (only for reminders while the app is
closed), and Screen Recording is optional (only for `⌃⌥S` screenshots). Both
are asked by macOS itself, once, and there's a Permissions helper in the menu
bar.
