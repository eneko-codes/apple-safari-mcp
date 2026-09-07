# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Nothing here modifies a bookmark or history entry — both are read-only. `close_tab` requires `confirm=true` and takes the tab's scroll position and back history with it. `run_javascript` executes in whatever tab is named, with no domain restriction — be certain of the target before calling it.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real Safari session, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

Reading a real tab is reading the owner's screen, and `close_tab` and `run_javascript` act on a session they are in the middle of using. All three need the ask above; none has a gentle route, because a fake tab is not the thing being debugged.

## What this is

A local MCP server (Swift 6, stdio transport) exposing Safari through Apple events, plus two tools that read Safari's own files (bookmarks, history). No network of its own. Safari must already be running; this server never launches it.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-safari-mcp | grep NSAppleEventsUsageDescription
```
