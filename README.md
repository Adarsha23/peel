# Peel

Floating sticky notes for macOS that stay out of your way. Native AppKit, one
~600 KB binary, zero dependencies, zero network. Notes are plain markdown files
you (and Claude Code) can read, grep, and edit directly.

Peel's stickies float above everything — including fullscreen video — without
stealing focus from the app you're using. Click a sticky and type; click back
into your app and it keeps playing, scrolling, working. The sticky stays.

## Install

```bash
cd ~/Projects/Peel
make install        # builds, signs, installs ~/Applications/Peel.app + `peel` CLI
peel                # launch (or focus, if already running)
```

To start Peel at login: System Settings → General → Login Items → add Peel.

## Shortcuts

**Global** (works from any app, any Space, fullscreen included)

| Key | Action |
| --- | --- |
| ⌘⇧Space | Summon the latest sticky / focus it / press again to hide all |
| ⌃⌥V | New sticky from the clipboard (text, image, or files) |
| Bottom screen edge | The shelf: tabs for every note slide up; click to open |

**In a sticky** — when no sticky is focused, your apps see nothing.

| Key | Action |
| --- | --- |
| esc / ⌘W | Hide the sticky |
| ⌘esc | Hide all stickies |
| ⌘T / ⌃⌥N | New sticky |
| ⌘↩ | Toggle todo on the current line (or click the box) |
| ⌘⌫ | Delete to line start; at line start keeps eating upward |
| Double-click header | Collapse the sticky to its first line / expand |
| ⌃⌥F | Search notes |
| ⌃⌥B | Push the sticky behind your windows / bring it back forward |
| ⌃⌥S | Screenshot straight into the note |
| ⌃⌥A | Archive the note |
| ⌃⌥1–7 | Change color |

Typing `/` on an empty line opens the command menu — type to filter, return or
click to apply. Every slash command lives there.

**Idle life-cycle** — an untouched sticky fades to ~40% opacity after 4 s (the
content underneath shows through), then minimizes into the shelf after 10 s
with a Dock-style animation. Hovering or focusing restores it instantly;
opening from the shelf expands out of its tab. Toggle with "Auto-tuck Idle
Stickies" in the menu bar, or set `autoDockSeconds` in `config.json`
(0 disables). Parked (⌃⌥B) stickies are exempt.

**Formatting** is live markdown: `**bold**` (⌘B), `*italic*` (⌘I),
`` `code` `` (⌘E), `~~strike~~` (⌘⇧X), `==highlight==` (⌘⇧H), `#` headings.
The shortcuts toggle-wrap the selection or the word at the caret; markers stay
visible but dimmed, and the file on disk is always plain markdown. The first
line of every note renders as its header — it's the note's name on the shelf,
in search, and in `peel list`.

**Typing** — `[]` + space starts a todo, `-` + space a bullet, Enter continues
lists (Enter on an empty item ends the list), ``` fences render as code, URLs
are clickable. Paste is always plain text.

**Slash commands** — type on an empty line and press return; the command
erases itself and runs:

| Command | Action |
| --- | --- |
| `/help` | Floating shortcut cheatsheet |
| `/new` `/search` | New sticky · search |
| `/hide` `/behind` | Hide · push behind / bring forward |
| `/archive` `/shot` | Archive · screenshot into note |
| `/date` `/time` | Insert `2026-09-14 Sun` · `14:32` |
| `/copy` | Copy the whole note as markdown |
| `/open` | Reveal the note file in Finder |
| `/yellow` … `/graphite` | Any palette name changes the color |

**Images & files** — paste or drop an image and it's saved to the note's
attachment folder and referenced inline right where your cursor/drop was, as a
clickable `⟦image-1.png⟧` tag (click to view). On disk that's a standard
markdown image link. Deleting a tag never deletes the file — it reappears in
the attachment strip at the bottom of the sticky. Non-image files go straight
to the strip; files over 100 MB are symlinked, not copied.

**Reminders** — type `/remind` and pick a time from the menu ("In 30 minutes",
"Tomorrow morning", …). It inserts `@remind Sep 15, 9:00 AM - what to remember`
with the message part pre-selected — just type your reminder text over it.
Everything on the line besides `@remind` and the time becomes the
notification message. You can also write it all by hand:
`@remind tomorrow 9am review the PR`.
Feedback is live: the token turns **orange with the understood time
underlined** when scheduled (hover for the exact date), **red** when no time
was recognized — or when notifications can't be delivered (permission off,
or not running the installed app). Click any `@remind` tag to pick or change
its time. Reminders play a soft two-note chime; picking a time previews it.
If a reminder didn't show, run `peel doctor` — it reports the real permission
state and lists every pending reminder with its fire time. macOS shows the
permission dialog over the desktop, not over fullscreen apps, so switch out
of fullscreen if you've never seen it.

## Terminal

```bash
peel                  # launch / focus
peel new "thought"    # create a note (also reads stdin)
peel list [--all]     # list notes
peel show <id>        # print a note + attachments (id prefix ok)
peel search <query>   # full-text search, includes archived
peel today            # every note touched today, as markdown
peel archive <id>     # archive (never deletes)
peel path             # print the data directory
peel ui <cmd>         # control the running app: toggle|new|search|show-all|hide-all
```

**Screenshots are searchable** — every image attachment is OCR'd on-device
(Apple's Vision framework, fully offline) into a hidden
`attachments/<id>/.ocr/` sidecar. `peel search "that error message"` finds the
screenshot containing it.

**Nothing is ever lost** — the data directory silently git-commits itself at
launch and every 6 hours, and "Start at Login" in the menu bar keeps Peel
always available.

## Where notes live

```
~/Library/Application Support/Peel/
    notes/20260914-135037-6prg.md      # frontmatter (color, frame, state) + markdown body
    attachments/20260914-135037-6prg/  # that note's images & files
    archive/                           # archived notes, never auto-deleted
    config.json                        # hotkey remapping
```

Override the location with `PEEL_DATA_DIR`. Deleted attachments go to the
Trash, not oblivion. A malformed note file loads as a plain-text note; it never
crashes the app.

## Claude Code

`make install` also installs a `peel-notes` skill into `~/.claude/skills/`, so
any Claude Code session knows where the notes live, how to search them, how to
resolve inline `![…](../attachments/<id>/…)` screenshot references (and view
them in the order they appear in the note), and how to write notes back onto
your screen with `peel new`. Point Claude Code at the data directory and
everything just works — notes are markdown, attachments are ordinary files
with relative links from the note:

```
"Read my sticky notes from today"   →  peel today
"Search my notes for auth"          →  peel search auth
```

The app watches the directory (events + a 2 s poll), so when Claude Code edits
a note file, the open sticky updates live — and `peel new` from a script pops a
sticky on screen.

## Architecture

- `Sources/PeelKit` — pure logic, no AppKit: note model, frontmatter parsing,
  markdown ⇄ editor-glyph mapping, file store, search, CLI. Fully unit-tested.
- `Sources/Peel` — the app: non-activating floating `NSPanel`s
  (`.canJoinAllSpaces` + `.fullScreenAuxiliary` is what survives fullscreen),
  Carbon global hotkey (no Accessibility permission needed), menu bar item,
  Spotlight-style search panel, notifications, directory watcher.
- One binary serves as app and CLI; `make app` wraps it into a bundle.

## Development

```bash
make run        # run from source (swift run Peel gui)
make test       # unit tests (25)
make app        # build dist/Peel.app
make install    # install to ~/Applications + CLI symlink
```

## macOS notes & limitations

- **Permissions**: none required for core use. Notifications ask once (for
  `@remind`). The screenshot feature drives `/usr/sbin/screencapture`, so no
  Screen Recording permission is needed.
- The app is ad-hoc signed for personal use — Gatekeeper is fine with it
  locally, but you can't distribute the bundle to other Macs as-is.
- Over a fullscreen app, macOS shows floating panels only while that Space is
  active — this is systemwide behavior for every overlay utility.
- ⌃⌥B (push behind) layers the sticky underneath normal windows. In a
  fullscreen Space there is nothing to go behind — macOS always composites
  panels above the fullscreen surface — so use esc/⌘⇧Space to tuck it away
  there instead.
- `⌘⇧Space` can be remapped in `config.json` (`"toggleHotkey"`), and optional
  global `"newNoteHotkey"` / `"searchHotkey"` specs can be added
  (e.g. `"ctrl+opt+n"`).
