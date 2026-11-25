import Foundation

/// Plain-text rendering of every tool result.
public struct Format: Sendable {
    let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    // MARK: Helpers

    static func pad(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? text + String(repeating: " ", count: shortfall) : text
    }

    static func block(_ rows: [(String, String?)]) -> String {
        let present = rows.compactMap { label, value -> (String, String)? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (label, value)
        }
        guard let width = present.map(\.0.count).max() else { return "" }
        let indent = String(repeating: " ", count: width + 3)
        return present.map { label, value in
            let wrapped = value.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n" + indent)
            return "  \(pad(label, to: width)) \(wrapped)"
        }.joined(separator: "\n")
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// `text` cut to `width` characters, with whether that cut anything.
    static func clip(_ text: String, to width: Int) -> (text: String, wasClipped: Bool) {
        text.count > width ? (String(text.prefix(width)) + "…", true) : (text, false)
    }

    /// One page of a listing: the notices, the sentence that places the page in the whole,
    /// and what `render` makes of the rows. `rows` is the page as the source gave it, at
    /// most `limit` of them, starting `offset` rows in. A page whose text is too long is
    /// halved until it fits, and its notice then says where to resume.
    ///
    /// `render` also returns the notices that depend on what it rendered, such as a field
    /// it clipped, so that such a notice is added only when a row on the page needed it.
    static func page<Row>(
        _ rows: [Row], offset: Int, total: Int, limit: Int, things: String, notices: [String],
        render: ([Row]) -> (body: String, notices: [String])
    ) -> String {
        ToolStandard.fitting(limit) { size in
            let shown = Array(rows.prefix(size))
            let rendered = render(shown)
            let position = Notice.page(offset: offset, count: shown.count, total: total, things: things)
            return ToolStandard.withNotices(
                notices + [position].compactMap { $0 } + rendered.notices, rendered.body)
        }
    }

    /// Collapses a multi-line value onto one line, so the one-line-per-result contract
    /// that makes a listing scannable survives a page title with a newline in it.
    static func oneLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// `2026-08-09 14:32`. Hand-rolled rather than `DateFormatter` so output does not
    /// change shape with the machine's locale: a model that has learned to read one form
    /// should not be handed another on a differently configured Mac.
    func timestamp(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0,
            parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }

    func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let month = parts.month.map { Self.months[($0 - 1) % 12] } ?? "???"
        return String(format: "%02d %@ %04d", parts.day ?? 0, month, parts.year ?? 0)
    }

    // MARK: Status

    public func status(
        _ state: SafariAvailability, library: LibraryStatus, binaryPath: String,
        configuration: Configuration
    ) -> String {
        let headline: String
        switch state {
        case .ready: headline = "Safari: RUNNING, automation permitted."
        case .notInstalled: headline = "Safari: NOT INSTALLED."
        case .notRunning: headline = "Safari: NOT RUNNING."
        case .automationDenied: headline = "Safari automation: DENIED."
        case .consentNotGranted: headline = "Safari automation: not requested yet."
        }

        func describe(_ access: LibraryAccess) -> String {
            switch access {
            case .readable: return "readable"
            case .blocked: return "BLOCKED — needs Full Disk Access, granted by hand"
            case .missing: return "file not present"
            }
        }

        var text = headline + "\n\n"
        // The effective configuration: a setting that never reached the process is
        // otherwise invisible, and has to be inferred from odd behaviour.
        text += Self.block([
            ("binary", binaryPath),
            ("target", "com.apple.Safari"),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
            ("bookmarks", describe(library.bookmarks)),
            ("history", describe(library.history)),
            ("raw page source", configuration.allowsPageSource ? "allowed" : "off"),
            (
                "run javascript",
                configuration.allowsJavaScript ? "allowed, in any tab" : "off"
            ),
            ("time limit", "\(ToolCatalog.callDeadline.components.seconds) seconds per call"),
        ])

        if state != .ready {
            text += "\n\n" + ToolError.availabilityMessage(state)
        }
        if library.bookmarks == .blocked || library.history == .blocked {
            text += """


                Bookmarks and history live in ~/Library/Safari, behind Full Disk Access.
                That grant has no key this server can declare and no dialog it can raise;
                it is given by hand in System Settings → Privacy & Security → Full Disk
                Access. Everything that goes through Safari itself — tabs, page text,
                open, close, Reading List — works without it.
                """
        }
        return text
    }

    // MARK: Tabs

    /// One tab of the listing, with the window it sits in.
    public struct TabRow: Sendable, Equatable {
        public let windowID: Int
        public let windowTitle: String
        public let tab: TabSummary

        public init(windowID: Int, windowTitle: String, tab: TabSummary) {
            self.windowID = windowID
            self.windowTitle = windowTitle
            self.tab = tab
        }
    }

    /// The order a page of tabs is given in: by window id, then by position from the left.
    /// No two tabs tie, because a position is unique inside a window.
    public static func tabRows(_ windows: [WindowInfo]) -> [TabRow] {
        windows.flatMap { window in
            window.tabs.map { TabRow(windowID: window.id, windowTitle: window.title, tab: $0) }
        }.sorted { ($0.windowID, $0.tab.id.index) < ($1.windowID, $1.tab.id.index) }
    }

    public func tabList(
        _ rows: [TabRow], offset: Int, total: Int, windows: Int, limit: Int, notices: [String]
    ) -> String {
        Self.page(
            rows, offset: offset, total: total, limit: limit, things: "tabs", notices: notices
        ) { rows in
            var titleClipped = false
            var urlClipped = false
            func fitTitle(_ text: String) -> String {
                let result = Self.clip(Self.oneLine(text), to: ToolCatalog.titleWidth)
                titleClipped = titleClipped || result.wasClipped
                return result.text
            }
            func fitURL(_ text: String) -> String {
                let result = Self.clip(text, to: ToolCatalog.urlWidth)
                urlClipped = urlClipped || result.wasClipped
                return result.text
            }
            guard total > 0 else {
                return (
                    """
                    Safari has no open windows.

                    It is running, but nothing is open to read. This server will not open a \
                    window on its own account; open_url will, if that is what was wanted.
                    """, []
                )
            }
            var lines = [
                "\(Self.plural(total, "tab")) in \(Self.plural(windows, "window")), ordered by window id, then by position from the left."
            ]
            if rows.isEmpty { lines += ["", "(nothing at this offset)"] }
            var currentWindow: Int?
            for row in rows {
                if row.windowID != currentWindow {
                    currentWindow = row.windowID
                    lines.append("")
                    lines.append("Window \(row.windowID) · \(fitTitle(row.windowTitle))")
                }
                lines.append("  \(row.tab.isCurrent ? "▸" : " ") \(fitTitle(row.tab.title))")
                lines.append("    \(fitURL(row.tab.url))")
                lines.append("    id: \(row.tab.id.encoded)")
            }
            lines.append("")
            lines.append(
                """
                A tab id names a position in a window, so it stops being valid the moment tabs \
                are closed or reordered. Read or close a tab soon after listing, and list again \
                if a call says the id has moved.
                """)
            var note: [String] = []
            if titleClipped {
                note.append(
                    Notice.clipped(field: "Title", width: ToolCatalog.titleWidth, tool: ToolCatalog.tabTextName))
            }
            if urlClipped {
                note.append(
                    Notice.clipped(field: "URL", width: ToolCatalog.urlWidth, tool: ToolCatalog.tabTextName))
            }
            return (lines.joined(separator: "\n"), note)
        }
    }

    /// One window of a tab's text, with the title and URL in full.
    public func tabContent(_ tab: TabContent, characterOffset: Int, maxCharacters: Int, notices: [String])
        -> String
    {
        let total = tab.content.count
        return ToolStandard.fitting(maxCharacters) { size in
            let window = ToolStandard.window(
                of: tab.content, characterOffset: characterOffset, maxCharacters: size)
            let header = Self.block([
                ("title", Self.oneLine(tab.title)),
                ("url", tab.url),
                ("kind", tab.kind == .text ? "rendered page text" : "raw HTML source"),
                ("length", "\(total) characters"),
            ])
            return ToolStandard.withNotices(
                notices + [window.notice].compactMap { $0 }, header + "\n\n" + window.text)
        }
    }

    public func opened(_ tab: OpenedTab, notices: [String] = []) -> String {
        var notes = notices
        let title = Self.clip(Self.oneLine(tab.title), to: ToolCatalog.titleWidth)
        let url = Self.clip(tab.url, to: ToolCatalog.urlWidth)
        if title.wasClipped {
            notes.append(
                Notice.clipped(field: "Title", width: ToolCatalog.titleWidth, tool: ToolCatalog.tabTextName))
        }
        if url.wasClipped {
            notes.append(
                Notice.clipped(field: "URL", width: ToolCatalog.urlWidth, tool: ToolCatalog.tabTextName))
        }
        return ToolStandard.withNotices(
            notes,
            """
            Opened in a new tab.

            \(Self.block([
                ("url", url.text),
                ("title", tab.title.isEmpty ? "(still loading)" : title.text),
                ("id", tab.id.encoded),
            ]))

            The page may still be loading. A title of "(still loading)" is normal straight \
            after opening; call tabs_list again in a moment.
            """)
    }

    public func closed(_ tab: TabSummary) -> String {
        // What was closed cannot be read again, so a cut field says so in the one sentence
        // the standard has for output that cannot be asked for twice.
        var notes: [String] = []
        func fit(_ text: String, _ width: Int) -> String {
            let result = Self.clip(text, to: width)
            if result.wasClipped {
                notes.append("Cut at \(width) of \(text.count) characters; the rest cannot be read again.")
            }
            return result.text
        }
        let title = fit(Self.oneLine(tab.title), ToolCatalog.titleWidth)
        let url = fit(tab.url, ToolCatalog.urlWidth)
        return ToolStandard.withNotices(
            notes,
            """
            Closed the tab. This cannot be undone from here.

            \(Self.block([
                ("title", title),
                ("url", url),
            ]))

            Reopening it is a menu gesture — History → Reopen Last Closed Tab — that only the \
            person at the keyboard can make, and any text typed into the page is gone.
            """)
    }

    /// The script's result, cut at `maxCharacters`. The script cannot be run a second time
    /// to read the rest, because it may have changed the page, so there is no offset: the
    /// sentence for output that cannot be asked for twice says so.
    public func javascriptResult(_ result: JavaScriptResult, maxCharacters: Int, notices: [String])
        -> String
    {
        ToolStandard.fitting(maxCharacters) { size in
            let total = result.result.count
            let cut = total > size
            let shown = cut ? String(result.result.prefix(size)) : result.result
            let note = cut ? ["Cut at \(size) of \(total) characters; the rest cannot be read again."] : []
            return ToolStandard.withNotices(
                notices + note,
                """
                Ran the script.

                \(Self.block([
                    ("tab", result.id.encoded)
                ]))

                Result: \(shown)
                """)
        }
    }

    public func readingListAdded(url: String, title: String?) -> String {
        """
        Added to the Reading List.

        \(Self.block([
            ("url", ToolStandard.echo(url)),
            ("title", title.map { ToolStandard.echo(Self.oneLine($0)) }),
        ]))

        Safari's scripting dictionary cannot read the Reading List back, so this server \
        cannot confirm the item landed, nor tell you it was already there. Safari accepts \
        the same URL twice without complaint.
        """
    }

    // MARK: Library

    public func bookmarkList(
        _ bookmarks: [Bookmark], offset: Int, total: Int, limit: Int, folder: String?,
        notices: [String]
    ) -> String {
        Self.page(
            bookmarks, offset: offset, total: total, limit: limit, things: "bookmarks",
            notices: notices
        ) { bookmarks in
            guard total > 0 else {
                return (
                    folder.map {
                        """
                        No bookmarks under a folder matching '\(ToolStandard.echo($0))'.

                        Folder matching is a case-insensitive prefix of the path, as shown in the \
                        'folder' column. Call bookmarks_list without a folder to see the paths \
                        that exist.
                        """
                    } ?? "Safari has no bookmarks.", []
                )
            }
            var lines = [
                "\(Self.plural(total, "bookmark")), in the order of Safari's bookmark tree."
            ]
            if let folder { lines.append("Folder filter: \(ToolStandard.echo(folder))") }
            if bookmarks.isEmpty { lines += ["", "(nothing at this offset)"] }
            for bookmark in bookmarks {
                lines.append("")
                lines.append("  \(Self.oneLine(bookmark.title))")
                lines.append("    \(bookmark.url)")
                if !bookmark.folderPath.isEmpty { lines.append("    folder: \(bookmark.folderPath)") }
            }
            return (lines.joined(separator: "\n"), [])
        }
    }

    public func historyResults(
        _ page: HistoryPage, offset: Int, limit: Int, query: String?, fromDate: Date?,
        toDate: Date?, notices: [String]
    ) -> String {
        let header = Self.block([
            ("query", query.map(ToolStandard.echo) ?? "(everything in range)"),
            ("from_date", fromDate.map(day) ?? "(no lower bound)"),
            ("to_date", toDate.map(day) ?? "(no upper bound)"),
            ("matches", "\(page.total), newest visit first"),
        ])
        return Self.page(
            page.results, offset: offset, total: page.total, limit: limit, things: "visits",
            notices: notices
        ) { results in
            guard page.total > 0 else {
                return (
                    header + """


                        Nothing in Safari's history matches.

                        History search looks at the URL and the page title, nothing else — the \
                        text of a page is not stored. Widen the date range, or drop the query \
                        entirely to see what is there.
                        """, []
                )
            }
            var lines = [header]
            if results.isEmpty { lines += ["", "(nothing at this offset)"] }
            for entry in results {
                lines.append("")
                lines.append("  \(timestamp(entry.visitedAt)) · \(Self.oneLine(entry.title))")
                lines.append("    \(entry.url)")
                if entry.visitCount > 1 {
                    lines.append("    visits: \(entry.visitCount) in total")
                }
            }
            return (lines.joined(separator: "\n"), [])
        }
    }
}
