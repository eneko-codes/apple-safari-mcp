# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## HARD RULE — THE OWNER'S BROWSING IS NOT YOURS TO READ OR DISTURB

**It is FORBIDDEN to read the text of the owner's open tabs, or to open, close or navigate
anything in their Safari.** This rule outranks every other instruction in this file. It
applies to every agent and every session.

Understand what `tab_get_text` actually reads. It is not a web page as the world sees it —
it is the page **as rendered in a logged-in session**: their bank, their email, a
half-written form, a document behind a paywall. Safari already fetched it, so no credential
is needed and no server is contacted. That is what makes the tool valuable, and it is
exactly what makes it off limits here.

Closing a tab is not recoverable either. A form filled in and not submitted is gone.

Never:

- call `tabs_list`, `tab_get_text` or `tab_get_source` against the owner's Safari;
- open or close a tab, or add anything to the reading list;
- read `~/Library/Safari/Bookmarks.plist` or the history database, by any route;
- print, log, paste or commit any real URL, page text, or bookmark;
- introduce a tool that runs JavaScript — see the invariants;
- leave anything behind that was not there when the session started.

**Fixtures first, always.** `FakeSafariStore` drives the whole tool layer with invented
windows, URLs and page bodies. Reach for a live test only for code the fake cannot reach —
everything below the `SafariStore` seam.

If a live check is genuinely unavoidable, ask the owner to open **one tab they choose**, on
a page they are happy for you to see, and confine yourself to it.

Allowed without asking:

| Action | Why it is safe |
|---|---|
| `swift build`, `swift test` | Tests run against the in-memory fake |
| `initialize`, `tools/list` over stdio | Protocol only; no Apple event is sent |
| `sdef /Applications/Safari.app` | Prints the dictionary |
| `otool -P` on the built binary | Inspects the embedded Info.plist |

Full verification remains the **owner's** job, by hand, with MCP Inspector.
`verification.md` is the script for it.

## Language

**Everything in this repository is written in English** — code, comments, tool
descriptions, error messages, documentation and commit messages. The one exception is
literal macOS UI strings quoted inside permission instructions.

## What this is

A local MCP server (Swift 6, stdio transport) exposing Safari through Apple events, plus two
tools that read Safari's own files. There is no network of its own: everything it returns,
Safari already had.

**Safari must be running, and this server never launches it.**

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-safari-mcp | grep NSAppleEventsUsageDescription
```

## Architecture

`Sources/SafariMCPCore` holds everything; `Sources/apple-safari-mcp/main.swift` is a
launcher that exists only because a Swift executable target cannot be imported by a test
target.

**`Sources/SafariBridge` is Objective-C, and not by preference** — the documented Scripting
Bridge pattern cannot be expressed in Swift (swiftlang/swift#43407). Only Foundation types
cross back.

Mind the importer's argument labels: `tabAtIndex:inWindow:` becomes `tab(at:inWindow:)`
because `At` reads as a preposition, while `openURL:` keeps its whole base name as
`openURL(_:)`.

**`SafariStore` is the seam**, and it deliberately covers both the Apple-event tools and the
two file-backed ones, so `Dispatch` never has to know which kind a call is.

## Invariants worth protecting

- **`do JavaScript` is not exposed, and must never be.** Safari's dictionary offers it. It
  would run arbitrary code inside whatever session the owner has open — their bank, their
  mail — and it needs a developer-menu setting enabled by hand besides. No tool here is
  worth that. A test asserts no tool name contains `script`.
- **A `TabID` carries a fingerprint of the URL it was minted for.** Safari addresses a tab by
  position, and positions shift the moment a tab is opened, closed or dragged. Without the
  fingerprint, a stale id would silently read whatever moved into that slot — the wrong page,
  reported as the right one. A mismatch **refuses** and says to call `tabs_list` again.
- **`close_tab` requires `confirm=true`.** A closed tab with unsaved state is not
  recoverable.
- **`tab_get_source` is opt-in twice:** it is a separate tool from `tab_get_text`, and it is
  gated by `allowsPageSource` in the configuration. Raw HTML of a logged-in page is a bigger
  disclosure than its text.
- **Page text is truncated at `pageCharacterLimit`**, and the response says so. A long
  article can otherwise swamp the conversation.
- **Bookmarks and history need Full Disk Access, which has no dialog and no plist key.** The
  only honest behaviour is to tell the three cases apart — readable, blocked, missing — and
  say which. `LibraryAccess.blocked` must never be rendered as an empty list: that would look
  like an empty browser rather than a missing permission.
- **Nothing here modifies a bookmark or the history.** Those files are read, never written.
- **No property may declare a union `type`.** A test walks the whole catalogue.
- **stdout carries JSON-RPC and nothing else.**

## Packaging as a Claude extension

`extension/manifest.json` plus `scripts/pack.sh` produce `dist/apple-safari-mcp.mcpb`. The
manifest's `tools` array creates the per-tool switches in Claude Desktop and is read before
the server has ever run.

Consider leaving `tab_get_source`, `bookmarks_list` and `history_search` switched off by
default when installing. The per-tool switches are the right place for that decision, not a
code change.

## TCC notes

Claude Desktop spawns MCP servers through `Contents/Helpers/disclaimer`, so the child is
**its own TCC subject**. The embedded `Resources/Info.plist` carries
`NSAppleEventsUsageDescription`; without it macOS denies Apple events **without ever
prompting**.

macOS only raises the Automation dialog when a real Apple event is sent, which is why
`consentNotGranted` does not block a call.

**Full Disk Access is separate, has no key and no prompt**, and is granted by hand in System
Settings → Privacy & Security → Full Disk Access. Only the two file-backed tools need it;
everything else works without.

**A linker-signed binary gets no TCC prompt.** `pack.sh` re-signs and prints the designated
requirement; an empty line there means the build is broken in a way nothing else will show.

## MCP servers

Applies to any repository shipping an MCP server or Claude extension: an `initialize` handler, a tool catalogue, or a manifest packed into a `.mcpb`.

**Shipping a rebuild**

- **ALWAYS bump the version before packing.** The installer keys on the manifest `version` alone, so a changed build under an already-installed version offers only "Uninstall" — which removes the extension instead of updating it.
- **Three files carry the version and must agree:** the manifest `version`, the server's own version constant (what `initialize` and the status tool report), and `CFBundleShortVersionString` in `Resources/Info.plist`. A test asserts all three; keep it.
- **Installing does not restart the server.** The running process serves the old binary until the client is fully quit and reopened, so a fix can appear to fail while the old code is still answering. Verify what is actually running (`ps`, and the binary path the status tool prints) before trusting any result, and ask for a full restart, not just an install.
- **Ad-hoc signing changes the cdhash on every rebuild**, so TCC forgets its grant and prompts again. Expected, not a fault — say so on handover.

**Documentation the model reads**

The server documents itself to a model, which acts on that text and cannot detect that it is wrong. Treat it as code, not prose.

- Update it in the same commit as the behaviour: a new, renamed or removed tool; a change to what a tool does, refuses, defaults to or requires; a change in which permission governs what; a limitation callers must work around.
- Four surfaces, all natural language: the server `instructions`, each tool `description`, each argument `description`, and the manifest's `tools` array and `long_description`. The manifest is read before the server has ever run, so a tool missing from it has no permission switch at all.
- State what the schema cannot convey: which tool to call first, which identifiers go stale and why, what cannot be undone, which permission governs what, and which field to prefer when several would fit.
- None of it takes effect until the client restarts. Say so on handover.
