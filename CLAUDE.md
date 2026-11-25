# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Nothing here modifies a bookmark or history entry — both are read-only. `close_tab` requires `confirm=true` and takes the tab's scroll position and back history with it. `run_javascript` executes in whatever tab is named, with no domain restriction — be certain of the target before calling it.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real Safari session, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

Reading a real tab is reading the owner's screen, and `close_tab` and `run_javascript` act on a session they are in the middle of using. All three need the ask above; none has a gentle route, because a fake tab is not the thing being debugged.

## What this is

A local MCP server (Swift 6, stdio transport) exposing Safari through Apple events, plus two tools that read Safari's own files (bookmarks, history). No network of its own. Safari must already be running; this server never launches it. **No third-party dependency**: `Package.swift` lists none, and the MCP protocol (JSON-RPC over stdio) is `MCPServer.swift` over Foundation. Adding a package needs the owner's say-so.

**`MCPServer.swift`, `Value.swift`, `ToolStandard.swift` and the tests `MCPProtocolTests.swift` and `ToolStandardTests.swift` are copied unchanged into every one of the owner's MCP servers** (the test files differ only in their `@testable import`). A change to one is made to every copy in the same piece of work; never let a copy drift.

`ToolStandard.swift` holds what every tool here must keep to: the longest result, description and error, the time a call may take, the fixed wording of each notice that says what a result left out (`Notice`), and the guard `MCPServer.swift` passes every result through. A tool bounds its own result and says how to get the rest; the guard only catches the one that forgot.

## Apple technology

Safari exposes no framework for its tabs, so those are Apple events: [ScriptingBridge](https://developer.apple.com/documentation/scriptingbridge) `SBApplication`/`SBElementArray`, with `AEDeterminePermissionToAutomateTarget` ([Apple Events](https://developer.apple.com/documentation/coreservices/apple_events)) to check consent without sending one. Bookmarks are read with [`PropertyListSerialization`](https://developer.apple.com/documentation/foundation/propertylistserialization); history is the [SQLite C API](https://www.sqlite.org/c3ref/intro.html), opened `mode=ro` **without** `immutable=1` so a read sees what Safari's write-ahead log still holds. Consent key: [`NSAppleEventsUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription).

## Native surface not used

`sdef /Applications/Safari.app` is the authority on the Apple-event side. Check it before proposing a tool.

- `email contents` — deliberately not declared.
- Reading List can be added to but never read back: the dictionary has no command for it.
- Bookmarks and history are read-only here, and there is no API to write either.

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

**Apple silicon only, deliberately.** `scripts/pack.sh` builds for arm64 alone — a plain `swift build -c release`, no `--arch` flags — and fails if the binary
holds any other architecture. A universal build doubles the bundle for an architecture
macOS 26 is the last release to support. Do not add an x86_64 slice back.

**An idle server must not poll stdin.** The MCP Swift SDK's `StdioTransport` (0.12.1) set stdin non-blocking and slept 10 ms between empty reads, which kept an idle server waking a hundred times a second; that is why this server once carried its own transport. The shared `serveStandardStreams` reads through `FileHandle.bytes.lines`, which leaves stdin blocking and does not wake while it is silent. `StandardStreamsTests` starts the built server with stdin open and counts its wakeups over an idle second to catch a regression.

**How a tool keeps to the tool standard here.** Sizes are constants in `ToolCatalog`, and the schemas, the descriptions and the instructions quote them by interpolation, never as literals. `Arguments.int` moves a quantity (`limit`, `offset`, a window) into its range and collects the sentence that says so in `notices`; an argument the tool's schema does not list is refused. A listing sorts its rows into an order it states and goes through `Format.page`, which puts the notices, the page's position (`Notice.page`) and any clipped-field notice before the data; `history_search` pages inside SQLite and passes the total back. `tab_get_text` and `tab_get_source` read the whole text from Safari and cut a window with `ToolStandard.window`. A script's result cannot be read twice, so `run_javascript` cuts it with the standard's sentence for that and has no offset. Every page and window renders through `ToolStandard.fitting`, so a tool never leans on the guard. `Deadline`, which abandons a call at its time limit, is part of `ToolStandard.swift`; `SafariBridgeEventTimeoutSeconds` (in the bridge header) is Safari's own wait for one Apple event and `ToolCatalog.callDeadline` is the whole call's, both inside `ToolStandard.timeLimit`. `BoundsTests` holds every bound, notice and length to this: a new listing takes `limit` and `offset` through `Arguments.page` and gets an entry in its `listings`. The README and the manifest state no figure the code owns; a test keeps it so.

## Diagnostics

Logs go to stderr through `Diagnostics`, which the host captures (Claude Desktop writes it to `~/Library/Logs/Claude/mcp-server-<name>.log`). stdout is the JSON-RPC stream: never `print`. The API takes no free-form text on purpose. Do not add one, and do not log an argument, a result, an error's `localizedDescription` or an identifier; log a fixed event, the tool name, the error's kind and a duration.
