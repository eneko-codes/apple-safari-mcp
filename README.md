<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="apple-safari-mcp icon">
</p>

# apple-safari-mcp

A local MCP server, written in Swift, exposing the macOS **Safari** app to Claude through
Apple events. It ships as a Claude extension.

It gives Claude read access to the windows and tabs already open, the rendered text of a
page already on screen, and the bookmarks and history stored on disk — plus three narrow
writes: open a URL in a new tab, close a tab, and add a page to the Reading List.

Not affiliated with or endorsed by Apple Inc.

## Requirements

- macOS 15 or later
- Swift 6.0 or later (Xcode 26 ships it)
- A code signing identity. Ad-hoc works, but every rebuild then asks for permission
  again — see [Signing](#signing-and-why-it-is-not-optional).

## Tools

| Tool | Kind | What it does |
|---|---|---|
| `safari_status` | read | Reports whether Safari is running, whether this server may control it, and whether bookmarks and history on disk can be read. Opens no page and reads no tab. |
| `tabs_list` | read | Every window and every tab in it — title, URL and the id needed to read or close it. Marks the frontmost tab in each window. |
| `tab_get_text` | read | Rendered text of a tab already open, cut at 40,000 characters. No network fetch: it reads whatever Safari already loaded. |
| `tab_get_source` | read | Raw HTML of a tab already open. **Off by default**, and currently cannot be turned on through the packaged extension — see [Known limits](#known-limits). |
| `open_url` | write | Opens a URL in a new tab in the frontmost window. Only `http` and `https`. |
| `close_tab` | **destructive** | Closes one tab. Requires `confirm: true`. Cannot be undone from here. |
| `reading_list_add` | write | Saves a URL to Safari's Reading List, with an optional title and preview line. Only `http` and `https`. |
| `bookmarks_list` | read | Saved bookmarks, with title, URL and folder path. Needs Full Disk Access. |
| `history_search` | read | Visited pages, matched by URL/title text and a date range, newest first. Needs Full Disk Access. |
| `run_javascript` | **destructive** | Runs JavaScript in a tab already open, in whatever session it holds. Requires `confirm: true`. **Off by default** — see [Tool switches](#tool-switches). |

## The rules worth knowing before you use it

**A tab id names a position, not a page.** Safari gives a tab no identifier of its own —
only where it sits, counted from the left of its window — so an id minted by `tabs_list`
goes stale the moment a tab is closed, reordered or navigates elsewhere. Every id also
carries a fingerprint of the URL it was made for, and a call against an id whose
fingerprint no longer matches is **refused**, not silently served against whatever moved
into that slot. Run `tabs_list` again and use the id it returns now.

**`tab_get_text` reads the page as rendered in that tab**, not what a fresh request for
the URL would return. No network fetch happens, so it reads exactly what the person
sees — a logged-in dashboard, a paywalled article, a half-filled form. Treat it as the
person's own screen, not as a public web page.

**`run_javascript` has no domain restriction.** Once it is switched on, it runs code in
whatever tab it is given — the same as Safari's own `do JavaScript` does for a person
driving it by hand, signed in or not. Choosing the right tab is the caller's job; nothing
here narrows it further. It also needs Safari's own **"Allow JavaScript from Apple
Events"** developer setting (Safari → Settings → Advanced → Show features for web
developers → Develop menu), off by default on every Mac — a call fails with that exact
instruction until it is turned on once, by hand. A `javascript:` URL passed to `open_url`
or `reading_list_add` is still refused: it is the same command reached by a different
route, and `run_javascript` is the one way in.

**`close_tab` is irreversible from here.** A closed tab takes its scroll position, its
form state and its back history with it; "Reopen Last Closed Tab" is a menu gesture only
the person at the keyboard can make. It requires `confirm: true`, and the id is verified
*before* the confirmation is checked, so a stale id is reported as stale rather than as a
missing confirmation.

**Bookmarks and history need Full Disk Access, a separate permission from Automation.**
Both live under `~/Library/Safari`, which is not covered by the Apple-events grant that
every other tool depends on — Full Disk Access has no usage-description key and no
programmatic prompt; it is granted by hand in System Settings. When it is missing, those
two tools fail with instructions naming the exact binary path to add, rather than
returning an empty list — an empty result there would read as an empty browser instead of
a missing permission. `safari_status` reports the two permissions separately.

## Install

### 1. Build the bundle

```bash
MCPB_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/pack.sh
```

That builds a universal (arm64 + x86_64) release binary, re-signs it (the linker's own
signature is `linker-signed`, which TCC treats as signed by nobody), checks the embedded
`Info.plist` survived both linking and signing, prints the designated requirement, and
writes `dist/apple-safari-mcp.mcpb`. It fails loudly rather than shipping a bundle that
would silently refuse to work.

```bash
security find-identity -v -p codesigning
```

### 2. Install it

Open `dist/apple-safari-mcp.mcpb` with Claude. Then **quit Claude Desktop completely and
reopen it** — reinstalling does not replace a server process that is already running, and
the old one keeps answering.

### 3. Grant the permissions

**Automation, first.** Open Safari — this server will not launch it for you. Call
`safari_status`, then a tab tool; macOS raises the Automation dialog on the first real
Apple event. Approve it, and the entry appears under:

```
System Settings → Privacy & Security → Automation → "apple-safari-mcp" → enable "Safari"
(Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Automatización)
```

The binary is **its own privacy subject**: Claude Desktop launches MCP servers through
`Contents/Helpers/disclaimer`, which calls `responsibility_spawnattrs_setdisclaim`, so the
child cannot inherit Claude.app's permissions — and Claude.app declares no Apple-events
usage description anyway. Hence the `Info.plist` embedded at link time. If no dialog ever
appears:

```bash
otool -P extension/server/apple-safari-mcp | grep NSAppleEventsUsageDescription
```

**Full Disk Access, separately, only for `bookmarks_list` and `history_search`.** It has
no usage-description key and no dialog this server can raise — it is granted entirely by
hand:

```
System Settings → Privacy & Security → Full Disk Access → + →
~/Library/Application Support/Claude/Claude Extensions/
  <extension folder>/server/apple-safari-mcp
```

Restart Claude Desktop afterwards: the grant is resolved when the process starts.
Everything else — tabs, opening, closing, the Reading List — works without it.

**"Allow JavaScript from Apple Events", separately, only for `run_javascript`.** This is
Safari's own developer setting, off by default on every Mac, and this server cannot flip
it — it is granted entirely by hand:

```
Safari → Settings → Advanced → turn on "Show features for web developers"
→ Develop menu → Allow JavaScript from Apple Events
```

Without it, `run_javascript` fails and names this exact setting. Everything else works
without it — this is the one tool that needs it.

### Signing, and why it is not optional

`swift build` leaves a signature the linker generated, flagged `linker-signed`. macOS
treats that as signed by nobody: it produces **no designated requirement**, so there is
nothing to anchor a permission to except the binary's cdhash — and every rebuild changes
that. Worse, a linker-signed binary never gets a consent dialog at all; the request
returns with the status still "not determined".

Signing with a real certificate produces a requirement anchored to the bundle identifier
and the certificate instead:

```
designated => identifier "codes.eneko.apple-safari-mcp" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: …"
```

That survives rebuilds. `pack.sh` prints the requirement on every build, so a silent
regression to ad-hoc is visible immediately.

**Changing certificate re-prompts once.** The requirement quotes the certificate, so
moving between ad-hoc, Apple Development and Developer ID each costs one fresh round of
consent.

### Preparing something to distribute

```bash
MCPB_HARDENED=1 MCPB_SIGN_IDENTITY="Developer ID Application: …" ./scripts/pack.sh
```

That adds the hardened runtime and a secure timestamp, which notarisation requires, and
applies `Resources/entitlements.plist` so hardened Apple events keep working.

## Tool switches

Every tool can be turned on and off individually in Claude Desktop → Settings →
Extensions, because the bundle declares all ten in its manifest — that is where policy
lives, not in this code. Consider leaving `tab_get_source`, `bookmarks_list` and
`history_search` off by default: the first exposes raw HTML of a logged-in page, and the
other two need a standing disk permission most people will not want to grant right away.

**`run_javascript` has its own settings checkbox — "Allow running JavaScript" — separate
from the per-tool switch above, because it gates the code path itself
(`Configuration.allowsJavaScript`), not just whether the tool can be called. Leave it off
until you mean for Claude to run code in any tab you point it at.**

**Reinstalling may reset the switches.** Check them after every install.

## Manual registration instead

```json
{
  "mcpServers": {
    "Apple Safari": {
      "command": "/absolute/path/to/apple-safari-mcp/.build/release/apple-safari-mcp"
    }
  }
}
```

You lose the per-tool switches. Do not do both at once: two registrations under the same
display name collide, and `safari_status` reports the binary path in use so you can tell
which one answered.

This is also, at present, the only way to turn `tab_get_source` on at all — see the next
section.

## Known limits

- **`tab_get_source` cannot currently be enabled through the packaged `.mcpb`.** It is
  gated by an internal `allowsPageSource` flag, off by default, that only a
  `--allow-page-source true` command-line argument can flip — and `extension/manifest.json`
  declares no `user_config` that would let Claude Desktop pass one. The Claude Desktop
  per-tool switch controls whether the tool can be *called* at all, which is a separate
  gate from this one; with no `user_config` wired up, the tool fails with "switched off"
  regardless of that switch. Enabling it means registering the binary manually with
  `"args": ["--allow-page-source", "true"]`.
- **The Reading List cannot be read back.** Safari's scripting dictionary has no command
  for it, so `reading_list_add` cannot report what is already saved and cannot tell a
  duplicate from a new item — the same URL added twice is accepted twice.
- **`history_search` matches only the URL and the page title.** The text of a visited page
  is not stored anywhere in `History.db`; answering "what did that page say" needs the
  page open and `tab_get_text`.
- **`open_url` and `reading_list_add` open only `http` and `https`.** `javascript:`,
  `file:` and `data:` are refused outright.
- **The exact wording `run_javascript` reports when "Allow JavaScript from Apple Events"
  is off is unverified.** The bridge detects the refusal and surfaces whatever
  `SBApplication`'s `lastError` says, but the precise message has not been checked
  against a live Safari with that setting off. This is deliberate, not an oversight: the codebase must never touch the owner's own Safari
  during development.
- **Safari must already be running.** This server will not launch it — starting a browser
  is a visible side effect nobody asked for.
- **Page text and source are capped at 40,000 characters per call.** A long page is
  truncated, and the response says so.

## Development

```bash
swift build
swift test
```

21 tests in one suite, all against an in-memory fake (`FakeSafariStore`) with Safari
closed and no permission granted — see `CLAUDE.md`, whose hard rule is that this server
must never read the owner's real open tabs or disturb their Safari session.

Manual verification against a live Safari, and against real bookmarks and history, is the
owner's job.

## Licence

MIT.
