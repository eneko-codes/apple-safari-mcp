# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Nothing here modifies a bookmark or history entry (both are read-only). `close_tab` requires `confirm=true`. `run_javascript` executes in whatever tab is named, with no domain restriction — be certain of the target tab before calling it.

## HARD RULE — TESTS NEVER RUN AGAINST THE OWNER'S REAL DATA

**Every test runs against fakes: in-memory doubles, fixtures, and data invented for the
test.** Never against real data the owner created. This rule outranks every other
instruction in this file — there is no "just this once", no "it is only a read so it is
harmless", and no putting-it-back-afterwards.

That covers the whole suite, a manual run of the built binary, and any check an agent does
on its own initiative "just to see". A test that reaches the owner's real store has stopped
testing this server and started using it.

**If you believe live data is genuinely needed, stop and ask before doing anything.** The
owner can grant an exception, but only for a specific check they have seen in full. Put it
to them in chat as an explicit choice — a question with options, not a remark inside a
longer message — and state:

1. exactly what you intend to run;
2. exactly which live data it would touch, named rather than summarised;
3. what it would create, change or delete, and whether that is reversible.

Go ahead only once the owner has chosen the option that allows it. An unrelated "go ahead",
a general permission from earlier in the session, or silence is not that consent — and the
exception covers only the run that was described, not the next one.

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
