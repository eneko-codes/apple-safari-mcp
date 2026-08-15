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
            ("page limit", "\(Configuration.pageCharacterLimit) characters"),
            ("default results", "\(Configuration.searchLimit)"),
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

    public func windowList(_ windows: [WindowInfo]) -> String {
        guard !windows.isEmpty else {
            return """
                Safari has no open windows.

                It is running, but nothing is open to read. This server will not open a
                window on its own account; open_url will, if that is what was wanted.
                """
        }

        let tabCount = windows.reduce(0) { $0 + $1.tabs.count }
        var lines = ["\(tabCount) tab\(tabCount == 1 ? "" : "s") in \(windows.count) window\(windows.count == 1 ? "" : "s")."]
        for window in windows {
            lines.append("")
            lines.append("Window \(window.id) · \(Self.oneLine(window.title))")
            for tab in window.tabs {
                lines.append("  \(tab.isCurrent ? "▸" : " ") \(Self.oneLine(tab.title))")
                lines.append("    \(tab.url)")
                lines.append("    id: \(tab.id.encoded)")
            }
        }
        lines.append("")
        lines.append(
            """
            A tab id names a position in a window, so it stops being valid the moment tabs \
            are closed or reordered. Read or close a tab soon after listing, and list again \
            if a call says the id has moved.
            """)
        return lines.joined(separator: "\n")
    }

    public func tabContent(_ tab: TabContent) -> String {
        var text = Self.block([
            ("title", Self.oneLine(tab.title)),
            ("url", tab.url),
            ("kind", tab.kind == .text ? "rendered page text" : "raw HTML source"),
            (
                "length",
                tab.truncated
                    ? "\(tab.content.count) of \(tab.totalCharacters) characters (TRUNCATED)"
                    : "\(tab.totalCharacters) characters"
            ),
        ])
        text += "\n\n" + tab.content
        if tab.truncated {
            text += """


                — cut at \(tab.content.count) characters. This is the beginning of the page, \
                not all of it.
                """
        }
        return text
    }

    public func opened(_ tab: OpenedTab) -> String {
        """
        Opened in a new tab.

        \(Self.block([
            ("url", tab.url),
            ("title", tab.title.isEmpty ? "(still loading)" : Self.oneLine(tab.title)),
            ("id", tab.id.encoded),
        ]))

        The page may still be loading. A title of "(still loading)" is normal straight \
        after opening; call tabs_list again in a moment.
        """
    }

    public func closed(_ tab: TabSummary) -> String {
        """
        Closed the tab. This cannot be undone from here.

        \(Self.block([
            ("title", Self.oneLine(tab.title)),
            ("url", tab.url),
        ]))

        Reopening it is a menu gesture — History → Reopen Last Closed Tab — that only the \
        person at the keyboard can make, and any text typed into the page is gone.
        """
    }

    public func readingListAdded(url: String, title: String?) -> String {
        """
        Added to the Reading List.

        \(Self.block([
            ("url", url),
            ("title", title.map(Self.oneLine)),
        ]))

        Safari's scripting dictionary cannot read the Reading List back, so this server \
        cannot confirm the item landed, nor tell you it was already there. Safari accepts \
        the same URL twice without complaint.
        """
    }

    // MARK: Library

    public func bookmarkList(_ bookmarks: [Bookmark], folder: String?, total: Int) -> String {
        guard !bookmarks.isEmpty else {
            return folder.map {
                """
                No bookmarks under a folder matching '\($0)'.

                Folder matching is a case-insensitive prefix of the path, as shown in the \
                'folder' column. Call bookmarks_list without a folder to see the paths \
                that exist.
                """
            } ?? "Safari has no bookmarks."
        }

        var lines: [String] = []
        lines.append(
            bookmarks.count == total
                ? "\(total) bookmark\(total == 1 ? "" : "s")."
                : "\(bookmarks.count) of \(total) bookmarks (limited).")
        if let folder { lines.append("Folder filter: \(folder)") }
        for bookmark in bookmarks {
            lines.append("")
            lines.append("  \(Self.oneLine(bookmark.title))")
            lines.append("    \(bookmark.url)")
            if !bookmark.folderPath.isEmpty { lines.append("    folder: \(bookmark.folderPath)") }
        }
        return lines.joined(separator: "\n")
    }

    public func historyResults(
        _ page: HistoryPage, query: String?, from: Date?, to: Date?
    ) -> String {
        var header = Self.block([
            ("query", query ?? "(everything in range)"),
            ("from", from.map(day) ?? "(no lower bound)"),
            ("to", to.map(day) ?? "(no upper bound)"),
            ("matches", "\(page.results.count)\(page.truncated ? " (limit reached)" : "")"),
        ])

        guard !page.results.isEmpty else {
            return header + """


                Nothing in Safari's history matches.

                History search looks at the URL and the page title, nothing else — the \
                text of a page is not stored. Widen the date range, or drop the query \
                entirely to see what is there.
                """
        }

        var lines = [header]
        for entry in page.results {
            lines.append("")
            lines.append("  \(timestamp(entry.visitedAt)) · \(Self.oneLine(entry.title))")
            lines.append("    \(entry.url)")
            if entry.visitCount > 1 {
                lines.append("    visits: \(entry.visitCount) in total")
            }
        }
        if page.truncated {
            lines.append("")
            lines.append(
                """
                Stopped at the limit; there are older matches behind these. Narrow the \
                range or raise 'limit'.
                """)
        }
        return lines.joined(separator: "\n")
    }
}
