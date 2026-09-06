import Foundation

@testable import SafariMCPCore

/// In-memory `SafariStore` for the tests.
///
/// Every fixture here is invented, and every host is `example.com` or a `.invalid`
/// domain, which can never resolve. The test suite must never reach the owner's real
/// Safari: see the hard rule in CLAUDE.md.
final class FakeSafariStore: SafariStore, @unchecked Sendable {
    var state: SafariAvailability
    var library: LibraryStatus
    var windowList: [WindowInfo]
    var bookmarkList: [Bookmark]
    var historyEntries: [HistoryEntry]

    /// Set to make the two disk-backed tools fail the way a missing Full Disk Access
    /// grant makes them fail.
    var bookmarksFailure: ToolError?
    var historyFailure: ToolError?

    /// Page bodies, by URL, so a test can ask for a page long enough to be truncated.
    var pageText: [String: String] = Fixtures.pageText
    var pageSource: [String: String] = Fixtures.pageSource

    private(set) var openedURLs: [String] = []
    private(set) var closedTabs: [TabID] = []
    private(set) var readingListItems: [(url: String, title: String?, previewText: String?)] = []
    private(set) var historyQueries: [(query: String?, from: Date?, to: Date?, limit: Int)] = []
    private(set) var scriptsRun: [(id: TabID, script: String)] = []

    /// What `runJavaScript` returns to whichever test set it, keyed by the exact script
    /// text — a fixed default lets most tests ignore this and still get an answer.
    var scriptResults: [String: String] = [:]
    var javascriptFailure: ToolError?

    init(
        state: SafariAvailability = .ready,
        library: LibraryStatus = LibraryStatus(bookmarks: .readable, history: .readable),
        windows: [WindowInfo] = Fixtures.windows,
        bookmarks: [Bookmark] = Fixtures.bookmarks,
        history: [HistoryEntry] = Fixtures.history
    ) {
        self.state = state
        self.library = library
        self.windowList = windows
        self.bookmarkList = bookmarks
        self.historyEntries = history
    }

    func availability() -> SafariAvailability { state }
    func libraryStatus() -> LibraryStatus { library }

    func windows() async throws -> [WindowInfo] { windowList }

    /// Resolves window and position exactly as the bridge does — by looking at what is
    /// there **now**, not at what the id claims. That is what lets a test hand over an id
    /// whose fingerprint no longer matches and see the guard fire.
    private func liveTab(_ id: TabID) throws -> TabSummary {
        guard let window = windowList.first(where: { $0.id == id.windowID }),
            let tab = window.tabs.first(where: { $0.id.index == id.index })
        else { throw ToolError.tabGone(id: id.encoded) }
        return tab
    }

    func tabSummary(_ id: TabID) async throws -> TabSummary { try liveTab(id) }

    func tabContent(_ id: TabID, kind: TabContentKind, characterLimit: Int) async throws
        -> TabContent
    {
        let tab = try liveTab(id)
        let whole = (kind == .text ? pageText[tab.url] : pageSource[tab.url]) ?? ""
        let truncated = whole.count > characterLimit
        return TabContent(
            id: id, title: tab.title, url: tab.url, kind: kind,
            content: truncated ? String(whole.prefix(characterLimit)) : whole,
            truncated: truncated, totalCharacters: whole.count)
    }

    func openURL(_ url: String) async throws -> OpenedTab {
        openedURLs.append(url)
        return OpenedTab(
            id: TabID(windowID: 1, index: windowList.first.map { $0.tabs.count + 1 } ?? 1, url: url),
            title: "", url: url)
    }

    func closeTab(_ id: TabID) async throws -> TabSummary {
        let tab = try liveTab(id)
        closedTabs.append(id)
        windowList = windowList.map { window in
            guard window.id == id.windowID else { return window }
            return WindowInfo(
                id: window.id, title: window.title,
                tabs: window.tabs.filter { $0.id.index != id.index })
        }
        return tab
    }

    func addReadingListItem(url: String, title: String?, previewText: String?) async throws {
        readingListItems.append((url, title, previewText))
    }

    func runJavaScript(_ id: TabID, script: String) async throws -> JavaScriptResult {
        _ = try liveTab(id)
        if let javascriptFailure { throw javascriptFailure }
        scriptsRun.append((id, script))
        return JavaScriptResult(
            id: id, script: script, result: scriptResults[script] ?? "(no value)")
    }

    func bookmarks() async throws -> [Bookmark] {
        if let bookmarksFailure { throw bookmarksFailure }
        return bookmarkList
    }

    func history(query: String?, from: Date?, to: Date?, limit: Int) async throws -> HistoryPage {
        historyQueries.append((query, from, to, limit))
        if let historyFailure { throw historyFailure }

        var matches = historyEntries
        if let query, !query.isEmpty {
            matches = matches.filter {
                $0.url.localizedCaseInsensitiveContains(query)
                    || $0.title.localizedCaseInsensitiveContains(query)
            }
        }
        if let from { matches = matches.filter { $0.visitedAt >= from } }
        if let to { matches = matches.filter { $0.visitedAt < to } }
        matches.sort { $0.visitedAt > $1.visitedAt }
        return HistoryPage(
            results: Array(matches.prefix(limit)), truncated: matches.count > limit)
    }
}

enum Fixtures {
    /// Fixed so a date bound is decided by the fixtures, not by when the suite runs.
    static let timeZone = TimeZone(identifier: "Europe/Madrid")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0)
        -> Date
    {
        calendar.date(
            from: DateComponents(
                timeZone: timeZone, year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    static let articleURL = "https://example.com/articles/tide-tables"
    static let dashboardURL = "https://dashboard.example.invalid/reports/2026"
    static let searchURL = "https://example.com/search?q=swift+scripting+bridge"
    static let manualURL = "https://docs.example.invalid/manual"

    static func tab(windowID: Int, index: Int, title: String, url: String, isCurrent: Bool = false)
        -> TabSummary
    {
        TabSummary(
            id: TabID(windowID: windowID, index: index, url: url), title: title, url: url,
            isCurrent: isCurrent)
    }

    /// Two windows, because a tab is addressed by window *and* position and a single
    /// window would let a bug in either half pass unnoticed.
    static let windows: [WindowInfo] = [
        WindowInfo(
            id: 101, title: "Tide tables",
            tabs: [
                tab(
                    windowID: 101, index: 1, title: "Tide tables for August",
                    url: articleURL, isCurrent: true),
                tab(windowID: 101, index: 2, title: "Quarterly reports", url: dashboardURL),
                tab(windowID: 101, index: 3, title: "swift scripting bridge", url: searchURL),
            ]),
        WindowInfo(
            id: 102, title: "Manual",
            tabs: [tab(windowID: 102, index: 1, title: "The manual", url: manualURL, isCurrent: true)]
        ),
    ]

    static let pageText: [String: String] = [
        articleURL: "High water at 04:12 and 16:38. Low water at 10:25 and 22:51.",
        dashboardURL: String(repeating: "Signed-in dashboard row. ", count: 400),
        searchURL: "Results for swift scripting bridge.",
        manualURL: "Chapter one. The manual begins here.",
    ]

    static let pageSource: [String: String] = [
        articleURL: "<html><head><title>Tide tables for August</title></head><body>…</body></html>",
        manualURL: "<html><body><h1>The manual</h1></body></html>",
    ]

    static let bookmarks: [Bookmark] = [
        Bookmark(folderPath: "", title: "Example", url: "https://example.com"),
        Bookmark(
            folderPath: "BookmarksBar", title: "Tide tables", url: articleURL),
        Bookmark(
            folderPath: "BookmarksBar/Reference", title: "The manual", url: manualURL),
        Bookmark(
            folderPath: "News", title: "Local news", url: "https://news.example.invalid"),
    ]

    static let history: [HistoryEntry] = [
        HistoryEntry(
            url: articleURL, title: "Tide tables for August",
            visitedAt: date(2026, 8, 9, 9, 30), visitCount: 12),
        HistoryEntry(
            url: manualURL, title: "The manual", visitedAt: date(2026, 8, 8, 18, 5),
            visitCount: 3),
        HistoryEntry(
            url: "https://example.com/weather", title: "Weather",
            visitedAt: date(2026, 8, 1, 7, 0), visitCount: 1),
    ]
}
