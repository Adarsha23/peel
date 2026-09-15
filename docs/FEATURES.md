# Peel, complete feature reference

Every feature in Peel, verified against the source. For the narrative version
see [OVERVIEW.md](OVERVIEW.md); for the quick pitch see the
[README](../README.md). The in-app `/help` cheatsheet mirrors most of this.

## Capture

- **Global summon** `⌘⇧Space` from any app: shows the latest note focused, or
  hides everything if a note is already up.
- **Clipboard capture** `⌃⌥V` from anywhere: turns whatever you copied (text,
  image, or files) into a new note.
- **Smart capture**: clipboard text is shaped deterministically (no network,
  no AI): a lone URL stays a clean link, code or an error is fenced as a code
  block, anything ambiguous is left exactly as pasted.
- **New note** `⌘T` or `⌃⌥N` inside a sticky; menu bar New Sticky; `peel new`.
- **Minimal open**: a note opens exactly as tall as its content (floor: header
  + one line) and grows as you type.
- **Autosave**: writes ~400 ms after you stop typing. No save button; survives
  crashes and force-quits.

## The overlay window

- **Floats over fullscreen** video and apps without pausing them.
- **Non-activating**: clicking a note doesn't steal focus from the app under
  it or switch your menu bar.
- **All Spaces**: visible on every desktop, including dedicated fullscreen Spaces.
- **Per-monitor memory**: each note remembers its position and size across
  restarts and monitors.
- **Park behind** `⌃⌥B` or `/behind`: drops a note beneath your normal windows;
  same key brings it back.
- **Idle ghost**: an untouched note fades translucent and collapses to just its
  header bar after ~4 s, so you read straight through it. Click it to restore.
- **Manual peek** `⌃⌥G`, `/ghost`, or the eye button in the header: fade and
  collapse right now instead of waiting for idle.
- **Lock opaque** `⌃⌥L`, `/lock`, or the dot menu: pins a note solid so it
  never fades. A lock glyph shows in the header.
- **Collapse** double-click the header: roll a note up to its first line;
  double-click again to expand.
- **Auto-tuck** (opt-in, menu bar): idle notes minimize into the shelf,
  Dock-style, instead of just ghosting.
- **Snap alignment**: dragging a note magnetizes its edges to other notes and
  to screen edges; slow drags snap, fast drags fly free.

## The shelf

- **Edge reveal**: push the cursor into a screen edge for a row of note tabs
  (first line as label, newest first); click one to open it.
- **Any edge**: bottom, top, left, or right, set in the menu bar or
  `config.json`; vertical edges show a column.
- **Close from the shelf**: hover a tab for a browser-style ✕, or ✕ all to
  clear every visible note.

## Writing

- **Live markdown**, plain text on disk: `**bold**` (`⌘B`), `*italic*` (`⌘I`),
  `` `code` `` (`⌘E`), `~~strike~~` (`⌘⇧X`), `==highlight==` (`⌘⇧H`),
  `#`/`##` headings. Markers stay visible but dimmed.
- **Todos**: `[]` + space starts one, click the box or `⌘↩` toggles it.
- **Lists**: `-` + space bullets; Enter continues a list, Enter on an empty
  item ends it; numbered lists auto-increment.
- **Code blocks**: ``` fences render monospaced.
- **Inline calculator**: type `240*1.18=` and the result appears after the `=`
  (supports `+ - * / ( )`, commas, `×`, `÷`).
- **Note links**: `[[note title]]` becomes a clickable pill that jumps to that
  note; typing `[[` autocompletes your titles; linking to a missing note
  creates it.
- **Text zoom** `⌘+` / `⌘−` / `⌘0`: per-note, persisted.
- **Seven colors** `⌃⌥1–7` or the dot menu: muted paper palettes.
- **Clickable URLs**; **paste is always plain text** (no rogue formatting).
- **Delete to line start** `⌘⌫`, and at the start of a line it keeps eating
  upward on repeat.
- **First line is the title** everywhere: shelf tabs, search, `peel list`.

## Slash command menu

Type `/` on an empty line for a menu (type to filter, click or return to run),
or type any of these on their own line:

- `/help` cheatsheet, `/new`, `/search`, `/hide`, `/behind`, `/ghost`,
  `/lock`, `/archive`, `/shot` (screenshot)
- `/remind` picks a time, or write it inline (`/remind in 20 min pay rent`)
- `/date`, `/time` insert the current date or time
- `/copy` copies the note as markdown, `/open` reveals the file in Finder
- `/count` (words, chars, lines), `/trim`, `/lower`, `/upper`
- any color name: `/yellow` `/cream` `/blue` `/green` `/lavender` `/pink` `/graphite`

## Images and files

- **Inline images**: paste or drop an image; it's saved to the note's folder
  and referenced as a clickable tag right where your cursor or drop was.
- **Delete-safe**: removing a tag doesn't delete the file; it returns to the
  attachment strip.
- **Screenshot into note** `⌃⌥S` or `/shot`: the note hides itself, you select
  a region, the image lands inline.
- **On-device OCR**: every image is text-recognized (Apple Vision, offline)
  into a hidden sidecar, so search finds words inside your screenshots.
- **File chips**: non-image files show as chips, click to open, right-click to
  reveal, copy path, or trash. Files over 100 MB are symlinked, not copied.

## Reminders

- **Natural language**: `@remind in 20 min ...`, `tomorrow 9am`, `Sep 20 2:30pm`.
- **Recurring**: `every day at 3pm`, `every weekday 9:30`, `every weekend 10am`,
  `every monday 9am`; they re-arm themselves after each fire.
- **Live feedback**: the recognized time underlines orange, red means it wasn't
  understood, with a tooltip showing exactly what's scheduled.
- **Picker**: `/remind` or clicking an `@remind` tag opens a time menu.
- **Native card**: at fire time Peel shows its own floating card (chime, note
  color, Open / Snooze 10 min / Done) that ignores Do Not Disturb, shows over
  fullscreen, and waits until you act on it.
- **System fallback**: when Peel is quit, scheduled system notifications cover
  it (this path needs notification permission).
- **`peel doctor`**: diagnoses the notification pipeline and lists pending
  reminders with fire times.

## Search, archive, history

- **Search** `⌃⌥F` or menu bar: Spotlight-style palette, live results,
  arrow-key nav, enter to jump; searches note text, filenames, and OCR'd
  screenshot text. Recent notes when the query is empty.
- **Archive** `⌃⌥A` or `/archive`: tucks a note away; nothing is ever deleted.
- **Trash, not oblivion**: removed attachments go to the Trash.
- **Auto git history**: the data folder commits itself at launch and every 6
  hours, so every note's history is recoverable.
- **Corrupt-safe**: a malformed note file loads as plain text instead of
  crashing the app.

## Terminal (CLI)

- `peel` launch or focus; `peel new "text"` (also reads stdin)
- `peel list [--all]`, `peel show <id>`, `peel search <query>`, `peel today`
- `peel archive <id>`, `peel path`
- `peel ui <toggle|new|search|show-all|hide-all|help|clip|shelf>` to drive the running app
- `peel doctor` for reminder diagnostics

## Live sync and Claude Code

- **Directory watching**: edit a note file from anywhere (an editor, a script,
  Claude Code) and the open sticky updates within ~2 s.
- **Bundled skill**: `make install` drops a `peel-notes` skill so Claude Code
  knows where notes live, resolves inline screenshots in order, greps the OCR
  sidecars, and pops results on screen with `peel new`.

## System integration

- **Menu bar home**: new, search, show/hide all, screenshot, open folder,
  shortcuts, permissions helper, shelf edge, auto-tuck, start at login, quit.
- **Start at Login** toggle (menu bar).
- **Standard Edit menu** (undo, redo, cut, copy, paste, select all) for the
  rare times the app is active.
- **Light and dark palettes** designed separately, not inverted.

## Customization (`config.json`)

- `keys`: remap every in-sticky action; pipe for multiple chords, `none` unbinds.
- `toggleHotkey`, `newNoteHotkey`, `searchHotkey`, `clipHotkey`: global hotkey specs.
- `shelfEdge`: bottom, top, left, right.
- `autoDockSeconds`: idle auto-tuck delay (0 disables).
- `PEEL_DATA_DIR` env var: move the whole data folder (point at iCloud for sync).

## Under the hood

- Native Swift/AppKit, one ~600 KB binary that is both the app and the CLI.
- Zero third-party dependencies, zero network calls, no telemetry, no account.
- Notes are markdown + flat frontmatter; PeelKit (the logic) is unit-tested and
  builds without Apple-only frameworks.
