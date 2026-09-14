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

**In a sticky** — commands use ⌃⌥ so they never collide with your browser or
terminal muscle memory. When no sticky is focused, your apps see nothing.

| Key | Action |
| --- | --- |
| esc | Hide the sticky |
| ⌘↩ | Toggle todo on the current line (or click the box) |
| ⌃⌥N | New sticky |
| ⌃⌥F | Search notes |
| ⌃⌥B | Push the sticky behind your windows / bring it back forward |
| ⌃⌥S | Screenshot straight into the note |
| ⌃⌥A | Archive the note |
| ⌃⌥1–7 | Change color |

**Typing** — `[]` + space starts a todo, `-` + space a bullet, Enter continues
lists (Enter on an empty item ends the list), ``` fences render as code, URLs
are clickable. Paste is always plain text.

**Images & files** — paste or drop an image and it's saved to the note's
attachment folder and referenced inline right where your cursor/drop was, as a
clickable `⟦image-1.png⟧` tag (click to view). On disk that's a standard
markdown image link. Deleting a tag never deletes the file — it reappears in
the attachment strip at the bottom of the sticky. Non-image files go straight
to the strip; files over 100 MB are symlinked, not copied.

**Reminders** — start a line with `@remind` plus a natural-language time
(`@remind tomorrow 9am review the PR`) and Peel schedules a local
notification. Requires notification permission (macOS asks once).

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

Point Claude Code at the data directory and everything just works — notes are
markdown, attachments are ordinary files with relative links from the note:

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
