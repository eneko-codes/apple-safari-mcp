# Manual verification

Everything below reads **your real browsing**, which is why no agent may run it (see the
hard rule in `CLAUDE.md`). Work through it yourself, in order.

```bash
npx @modelcontextprotocol/inspector ./.build/release/apple-safari-mcp
```

## 0 — Before you start

Open Safari with a window containing three tabs you do not mind reading aloud — a news
article, a documentation page, and a search results page. Open a second window with one
tab. Keep anything private closed for the duration.

## 1 — Permission plumbing

| Step | Call | Expected |
|---|---|---|
| 1.1 | Quit Safari, then `tabs_list` | Refused, saying Safari is not running — and **Safari does not launch**. |
| 1.2 | Open Safari, then `tabs_list` | The Automation dialog appears, quoting the usage description. |
| 1.3 | Approve, then `safari_status` | Granted; reports whether bookmarks and history are readable. |
| 1.4 | Deny (System Settings → Privacy & Security → Automation), restart, call again | Refused with the exact pane to re-enable. |

## 2 — Tabs

| Step | Call | Expected |
|---|---|---|
| 2.1 | `tabs_list` | Both windows, every tab, with titles, URLs and ids; the frontmost tab in each window marked current. |
| 2.2 | `tab_get_text` on the article | The rendered text — no HTML tags, no navigation chrome soup. |
| 2.3 | Compare with the page on screen | The body text matches. |
| 2.4 | `tab_get_text` on a very long page | Truncated at the fixed limit, and the response says so. |
| 2.5 | `tab_get_source` with the setting off | Refused, explaining it is disabled. |
| 2.6 | Enable page source, restart, `tab_get_source` | Raw HTML. |

## 3 — The staleness guard

This is the invariant the whole `TabID` design exists for.

| Step | Call | Expected |
|---|---|---|
| 3.1 | `tabs_list`, keep the id of the **second** tab | |
| 3.2 | In Safari, close the **first** tab, so everything shifts left by one | |
| 3.3 | `tab_get_text` with the id from 3.1 | **Refused**, saying the tab changed and to call `tabs_list` again. |
| 3.4 | `tabs_list` again, then read that tab | Works. |
| 3.5 | `tab_get_text` with a made-up id | Refused as unparseable. |

Step 3.3 is the one that matters. If it returns the text of a different page, the fingerprint
check has broken and every id in this server is now a lie.

## 4 — Opening and closing

| Step | Call | Expected |
|---|---|---|
| 4.1 | `open_url` with `https://example.com` | Opens; the response carries an id for the new tab. |
| 4.2 | `open_url` with `file:///etc/passwd` | Refused — the scheme is not one this server opens. |
| 4.3 | `open_url` with `javascript:alert(1)` | Refused. |
| 4.4 | `close_tab` **without** `confirm` | Refused. The tab is still open. |
| 4.5 | `close_tab` with `confirm: true` | Closed. |
| 4.6 | `reading_list_add` with a URL | Appears in Safari's reading list. |

## 5 — Bookmarks and history, which need Full Disk Access

| Step | Call | Expected |
|---|---|---|
| 5.1 | Before granting: `safari_status` | Reports bookmarks and history as blocked, naming System Settings → Privacy & Security → Full Disk Access. |
| 5.2 | `bookmarks_list` in that state | **Refused with that instruction** — not an empty list. |
| 5.3 | `history_search` in that state | Same. |
| 5.4 | Grant Full Disk Access to the installed binary, restart Claude Desktop, `bookmarks_list` | Your bookmarks, with folders. |
| 5.5 | `history_search` for a site you visited today | Found, with visit dates. |
| 5.6 | `history_search` with a date range | Filters correctly. |

The binary to grant lives at
`~/Library/Application Support/Claude/Claude Extensions/local.mcpb.eneko-codes.apple-safari-mcp/server/apple-safari-mcp`.

Steps 5.2 and 5.3 are the point: a missing permission must not read as an empty browser.

## 6 — What is deliberately absent

| Step | Call | Expected |
|---|---|---|
| 6.1 | Search `tools/list` for anything JavaScript-related | Nothing. Safari's dictionary offers `do JavaScript`; this server does not. |
| 6.2 | Look for a bookmark or history **write** tool | Nothing. Those files are read, never written. |

## 7 — Packaging

| Step | Command | Expected |
|---|---|---|
| 7.1 | `otool -P .build/release/apple-safari-mcp \| grep NSAppleEventsUsageDescription` | Present. |
| 7.2 | `MCPB_SIGN_IDENTITY="Apple Development: …" bash scripts/pack.sh` | Every check passes; the designated-requirement line is not empty. |
| 7.3 | `codesign -dv extension/server/apple-safari-mcp` | `flags=0x0(none)` — never `linker-signed`. |
| 7.4 | Install, restart Claude Desktop | Nine switches appear, one per tool. |

## 8 — Afterwards

Decide deliberately which tools to leave on. `tab_get_text` reads whatever you have open,
including pages behind a login — that is what makes it useful and what makes it worth
thinking about. `tab_get_source`, `bookmarks_list` and `history_search` are reasonable ones
to leave switched off until you want them.
