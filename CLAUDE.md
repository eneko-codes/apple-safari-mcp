# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Nothing here modifies a bookmark or history entry (both are read-only). `close_tab` requires `confirm=true`. `run_javascript` executes in whatever tab is named, with no domain restriction — be certain of the target tab before calling it.

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
