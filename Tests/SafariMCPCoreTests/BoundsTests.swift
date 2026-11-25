import Foundation
import Testing

@testable import SafariMCPCore

/// The edges of the tool standard for this server's own tools: each bound and one past it,
/// the text of each notice, pages and windows that chain, the longest result, and the texts
/// the model reads. Every tab, address and page in here is invented.
@Suite("Bounds")
struct BoundsTests {

    private static func call(
        _ name: String, _ arguments: [String: Value] = [:], store: FakeSafariStore = FakeSafariStore(),
        configuration: Configuration = Configuration(), deadline: Duration = ToolCatalog.callDeadline
    ) async -> (text: String, isError: Bool) {
        let tools = SafariTools(
            store: store, calendar: Fixtures.calendar, configuration: configuration,
            deadline: deadline)
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text) = result.content.first else { return ("(no text content)", true) }
        return (text, result.isError)
    }

    private static func padded(_ index: Int) -> String { String(format: "%04d", index) }

    /// `lead` followed by filler, `width` characters long in all.
    private static func widened(_ lead: String, to width: Int) -> String {
        lead + String(repeating: "x", count: max(width - lead.count, 0))
    }

    // MARK: Listings with as many rows as a test asks for

    /// One listing tool, and a Safari that gives it `count` rows of the widest width that is
    /// not clipped, in the order the tool lists them. `row` is text found in row `index` only.
    private struct Listing: Sendable, CustomTestStringConvertible {
        var tool: String
        var things: String
        var limits: ClosedRange<Int>
        var defaultLimit: Int
        var store: @Sendable (Int) -> FakeSafariStore
        var row: @Sendable (Int) -> String
        var order: String

        var testDescription: String { tool }

        func call(_ count: Int, _ arguments: [String: Value] = [:]) async -> (text: String, isError: Bool) {
            await BoundsTests.call(tool, arguments, store: store(count))
        }

        func rows(in text: String, of count: Int) -> [Int] {
            (0..<count).filter { text.contains(row($0)) }
        }
    }

    private static let tabs = Listing(
        tool: ToolCatalog.tabsListName, things: "tabs", limits: ToolCatalog.tabLimitRange,
        defaultLimit: ToolCatalog.defaultTabLimit,
        store: { count in
            let tabs = (0..<count).map { index in
                let url = widened("https://example.com/tab-\(padded(index))-", to: ToolCatalog.urlWidth)
                return TabSummary(
                    id: TabID(windowID: 7, index: index + 1, url: url),
                    title: widened("tab-\(padded(index))-", to: ToolCatalog.titleWidth), url: url,
                    isCurrent: index == 0)
            }
            return FakeSafariStore(windows: count == 0 ? [] : [WindowInfo(id: 7, title: "Invented", tabs: tabs)])
        },
        row: { "tab-\(padded($0))-" }, order: "ordered by window id, then by position from the left")

    private static let bookmarks = Listing(
        tool: ToolCatalog.bookmarksListName, things: "bookmarks", limits: ToolCatalog.bookmarkLimitRange,
        defaultLimit: ToolCatalog.defaultBookmarkLimit,
        store: { count in
            FakeSafariStore(
                bookmarks: (0..<count).map {
                    Bookmark(
                        folderPath: widened("Invented/Folder/", to: 60),
                        title: widened("mark-\(padded($0))-", to: 100),
                        url: widened("https://example.com/mark-\(padded($0))-", to: 200))
                })
        },
        row: { "mark-\(padded($0))-" }, order: "in the order of Safari's bookmark tree")

    private static let history = Listing(
        tool: ToolCatalog.historySearchName, things: "visits", limits: ToolCatalog.historyLimitRange,
        defaultLimit: ToolCatalog.defaultHistoryLimit,
        store: { count in
            FakeSafariStore(
                history: (0..<count).map {
                    // Newest first is index order, so row 0 is the newest.
                    HistoryEntry(
                        url: widened("https://example.com/visit-\(padded($0))-", to: 200),
                        title: widened("visit-\(padded($0))-", to: 100),
                        visitedAt: Fixtures.date(2026, 8, 9, 12).addingTimeInterval(-Double($0) * 60),
                        visitCount: 12_345)
                })
        },
        row: { "visit-\(padded($0))-" }, order: "newest visit first")

    private static let listings = [tabs, bookmarks, history]

    // MARK: Pages

    @Test("A call with no optional argument returns one default page, announced before the data", arguments: listings)
    private func defaultPage(_ listing: Listing) async {
        let total = listing.defaultLimit + 5
        let result = await listing.call(total)
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(listing.defaultLimit) of \(total) \(listing.things). Pass offset=\(listing.defaultLimit) for the next page.\n\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<listing.defaultLimit))
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
    }

    @Test("A result that holds every row from the start carries no notice", arguments: listings)
    private func wholeListingHasNoNotice(_ listing: Listing) async {
        let result = await listing.call(listing.defaultLimit)
        #expect(listing.rows(in: result.text, of: listing.defaultLimit).count == listing.defaultLimit)
        #expect(!result.text.contains("Showing"))
        #expect(!result.text.contains("is outside"))
        #expect(!result.text.contains("clipped"))
    }

    @Test("limit at its maximum is used as asked, and a full page of the widest rows fits a result", arguments: listings)
    private func limitAtItsMaximum(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10
        let result = await listing.call(total, ["limit": .int(maximum)])
        #expect(!result.text.contains("is outside"))
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(maximum) of \(total) \(listing.things). Pass offset=\(maximum) for the next page.\n\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<maximum))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("limit one past either end is moved to the nearest value, and the result says which", arguments: listings)
    private func limitPastItsRange(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10

        let over = await listing.call(total, ["limit": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                """
                limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.
                Showing 1–\(maximum) of \(total) \(listing.things). Pass offset=\(maximum) for the next page.


                """))
        #expect(listing.rows(in: over.text, of: total) == Array(0..<maximum))

        let under = await listing.call(total, ["limit": .int(0)])
        #expect(under.text.hasPrefix("limit=0 is outside 1–\(maximum); 1 was used.\nShowing 1–1 of \(total) "))
        #expect(listing.rows(in: under.text, of: total) == [0])
    }

    @Test("Each page starts where the last one ended, and the last says that is all", arguments: listings)
    private func pagesChain(_ listing: Listing) async {
        let first = await listing.call(7, ["limit": .int(3)])
        #expect(first.text.hasPrefix("Showing 1–3 of 7 \(listing.things). Pass offset=3 for the next page.\n\n"))
        #expect(listing.rows(in: first.text, of: 7) == [0, 1, 2])

        let second = await listing.call(7, ["limit": .int(3), "offset": .int(3)])
        #expect(second.text.hasPrefix("Showing 4–6 of 7 \(listing.things). Pass offset=6 for the next page.\n\n"))
        #expect(listing.rows(in: second.text, of: 7) == [3, 4, 5])

        let last = await listing.call(7, ["limit": .int(3), "offset": .int(6)])
        #expect(last.text.hasPrefix("Showing 7–7 of 7 \(listing.things). That is all.\n\n"))
        #expect(listing.rows(in: last.text, of: 7) == [6])
    }

    @Test("An offset past the end returns no row and says so; a negative one is moved to zero", arguments: listings)
    private func offsetEdges(_ listing: Listing) async {
        let past = await listing.call(7, ["offset": .int(7)])
        #expect(!past.isError)
        #expect(past.text.hasPrefix("Showing 0 of 7 \(listing.things): offset=7 is past the end. That is all.\n\n"))
        #expect(listing.rows(in: past.text, of: 7).isEmpty)
        #expect(past.text.contains("(nothing at this offset)"))

        let negative = await listing.call(7, ["offset": .int(-1)])
        let range = ToolCatalog.offsetRange
        #expect(negative.text.hasPrefix("offset=-1 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\n\n"))
        #expect(listing.rows(in: negative.text, of: 7) == Array(0..<7))

        let beyond = await listing.call(7, ["offset": .int(range.upperBound + 1)])
        #expect(beyond.text.hasPrefix("offset=\(range.upperBound + 1) is outside "))
    }

    @Test("A listing states its order", arguments: listings)
    private func orderIsStated(_ listing: Listing) async {
        #expect(await listing.call(1).text.contains(listing.order))
    }

    @Test("An empty listing carries no paging notice", arguments: listings)
    private func emptyListing(_ listing: Listing) async {
        let result = await listing.call(0)
        #expect(!result.isError)
        #expect(!result.text.contains("Showing"))
    }

    @Test("Tabs of several windows are listed by window id, then position, whatever order Safari gives")
    func tabsAreOrdered() async {
        func tab(_ window: Int, _ index: Int) -> TabSummary {
            let url = "https://example.com/w\(window)-\(index)"
            return TabSummary(
                id: TabID(windowID: window, index: index, url: url), title: "w\(window)t\(index)",
                url: url, isCurrent: false)
        }
        let store = FakeSafariStore(windows: [
            WindowInfo(id: 9, title: "Nine", tabs: [tab(9, 2), tab(9, 1)]),
            WindowInfo(id: 3, title: "Three", tabs: [tab(3, 1)]),
        ])
        let text = await Self.call(ToolCatalog.tabsListName, store: store).text
        let positions = ["w3t1", "w9t1", "w9t2"].compactMap { text.range(of: $0)?.lowerBound }
        #expect(positions.count == 3 && positions == positions.sorted())
        #expect(text.contains("3 tabs in 2 windows"))
    }

    // MARK: Fields clipped inside a row

    @Test("A title or URL longer than its width is clipped and announced, and one at the width is not")
    func clippedFields() async {
        let longTitle = String(repeating: "t", count: ToolCatalog.titleWidth + 1)
        let longURL = "https://example.com/" + String(repeating: "u", count: ToolCatalog.urlWidth)
        let url = "https://example.com/short"
        let store = FakeSafariStore(windows: [
            WindowInfo(
                id: 1, title: "Invented",
                tabs: [
                    TabSummary(
                        id: TabID(windowID: 1, index: 1, url: longURL), title: longTitle, url: longURL,
                        isCurrent: true),
                    TabSummary(
                        id: TabID(windowID: 1, index: 2, url: url), title: "short", url: url,
                        isCurrent: false),
                ])
        ])
        let result = await Self.call(ToolCatalog.tabsListName, store: store)
        #expect(result.text.contains("Title is clipped to \(ToolCatalog.titleWidth) characters in each row. Read one in full with tab_get_text."))
        #expect(result.text.contains("URL is clipped to \(ToolCatalog.urlWidth) characters in each row. Read one in full with tab_get_text."))
        #expect(!result.text.contains(longURL))

        // tab_get_text shows both in full, which is what the notice promises.
        store.pageText[longURL] = "body"
        let id = TabID(windowID: 1, index: 1, url: longURL).encoded
        let full = await Self.call(ToolCatalog.tabTextName, ["id": .string(id)], store: store)
        #expect(full.text.contains(longURL))
        #expect(full.text.contains(longTitle))
    }

    // MARK: One long text

    private static func pageStore(_ text: String) -> (FakeSafariStore, String) {
        let store = FakeSafariStore()
        store.pageText[Fixtures.articleURL] = text
        return (store, TabID(windowID: 101, index: 1, url: Fixtures.articleURL).encoded)
    }

    @Test("A page longer than the default window gives its first window and says how to read the rest")
    func longPageFirstWindow() async {
        let total = ToolCatalog.defaultMaxCharacters * 2 + 500
        let (store, id) = Self.pageStore(String(repeating: "a", count: total))
        let result = await Self.call(ToolCatalog.tabTextName, ["id": .string(id)], store: store)
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "Characters 1–\(ToolCatalog.defaultMaxCharacters) of \(total). Pass character_offset=\(ToolCatalog.defaultMaxCharacters) for the rest.\n\n"))
        #expect(result.text.utf16.count <= ToolStandard.usualPage + 1_000)
        #expect(!result.text.contains("TRUNCATED"))
    }

    @Test("Windows of a page chain from the first character to the last, for text and for source")
    func windowsChain() async throws {
        let text = (0..<2_500).map { "w\(Self.padded($0)) " }.joined()
        for tool in [ToolCatalog.tabTextName, ToolCatalog.tabSourceName] {
            let store = FakeSafariStore()
            store.pageText[Fixtures.articleURL] = text
            store.pageSource[Fixtures.articleURL] = text
            let id = TabID(windowID: 101, index: 1, url: Fixtures.articleURL).encoded
            var configuration = Configuration()
            configuration.allowsPageSource = true

            var offset = 0
            var rebuilt = ""
            var calls = 0
            while offset < text.count {
                let result = await Self.call(
                    tool,
                    ["id": .string(id), "character_offset": .int(offset), "max_characters": .int(1_000)],
                    store: store, configuration: configuration)
                #expect(!result.isError)
                let last = min(offset + 1_000, text.count)
                let ending =
                    last < text.count ? "Pass character_offset=\(last) for the rest." : "That is all."
                #expect(result.text.hasPrefix("Characters \(offset + 1)–\(last) of \(text.count). \(ending)\n\n"))
                let body = try #require(result.text.range(of: "characters\n\n")).upperBound
                rebuilt += String(result.text[body...])
                offset = last
                calls += 1
            }
            #expect(rebuilt == text)
            #expect(calls == 15)
        }
    }

    @Test("A page that fits one window carries no notice, and an offset past its end says so")
    func shortPageAndPastTheEnd() async {
        let (store, id) = Self.pageStore("Short page.")
        let whole = await Self.call(ToolCatalog.tabTextName, ["id": .string(id)], store: store)
        #expect(whole.text.contains("Short page."))
        #expect(!whole.text.contains("Characters"))

        let past = await Self.call(
            ToolCatalog.tabTextName, ["id": .string(id), "character_offset": .int(11)], store: store)
        #expect(past.text.hasPrefix("Characters 0 of 11: character_offset=11 is past the end. That is all.\n\n"))
    }

    @Test("max_characters and character_offset are moved into their ranges, and the result says which")
    func windowArgumentsAreClamped() async {
        let (store, id) = Self.pageStore(String(repeating: "a", count: 50_000))
        let range = ToolCatalog.maxCharactersRange
        let over = await Self.call(
            ToolCatalog.tabTextName, ["id": .string(id), "max_characters": .int(range.upperBound + 1)],
            store: store)
        #expect(over.text.hasPrefix("max_characters=\(range.upperBound + 1) is outside 1–\(range.upperBound); \(range.upperBound) was used.\n"))
        #expect(over.text.utf16.count <= ToolStandard.longestResult)

        let under = await Self.call(
            ToolCatalog.tabTextName, ["id": .string(id), "max_characters": .int(0)], store: store)
        #expect(under.text.hasPrefix("max_characters=0 is outside 1–\(range.upperBound); 1 was used.\nCharacters 1–1 of 50000."))

        let negative = await Self.call(
            ToolCatalog.tabTextName, ["id": .string(id), "character_offset": .int(-5)], store: store)
        #expect(negative.text.hasPrefix("character_offset=-5 is outside "))
    }

    @Test("A window of characters that take two UTF-16 units each holds fewer and says where to resume")
    func wideWindowShrinks() async throws {
        let total = 60_000
        let (store, id) = Self.pageStore(String(repeating: "😀", count: total))
        let result = await Self.call(
            ToolCatalog.tabTextName,
            ["id": .string(id), "max_characters": .int(ToolCatalog.maxCharactersRange.upperBound)],
            store: store)
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        #expect(!result.text.hasPrefix("Cut at"))
        let notice = try #require(result.text.split(separator: "\n").first)
        let shown = try #require(Int(notice.split(separator: " ")[1].split(separator: "–")[1]))
        #expect(shown < ToolCatalog.maxCharactersRange.upperBound)
        #expect(notice.contains("Pass character_offset=\(shown) for the rest."))
    }

    // MARK: A script's result

    private static func scripted(_ result: String, arguments: [String: Value] = [:]) async -> (text: String, isError: Bool) {
        var configuration = Configuration()
        configuration.allowsJavaScript = true
        let store = FakeSafariStore()
        store.scriptResults["big()"] = result
        let id = TabID(windowID: 101, index: 1, url: Fixtures.articleURL).encoded
        var call: [String: Value] = [
            "id": .string(id), "script": .string("big()"), "confirm": .bool(true),
        ]
        call.merge(arguments) { _, new in new }
        return await Self.call(ToolCatalog.runJavaScriptName, call, store: store, configuration: configuration)
    }

    @Test("A script result longer than the window is cut with the sentence for output that cannot be asked for twice")
    func longScriptResultIsCut() async {
        let limit = ToolCatalog.defaultMaxCharacters
        let total = limit + 7
        let result = await Self.scripted(String(repeating: "r", count: total))
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Cut at \(limit) of \(total) characters; the rest cannot be read again.\n\n"))
        #expect(result.text.utf16.count <= ToolStandard.usualPage + 1_000)

        let whole = await Self.scripted(String(repeating: "r", count: limit))
        #expect(!whole.text.contains("Cut at"))
    }

    @Test("max_characters raises the bound of a script result, within its range")
    func scriptResultBoundIsAnArgument() async {
        let range = ToolCatalog.maxCharactersRange
        let result = await Self.scripted(
            String(repeating: "r", count: 30_000), arguments: ["max_characters": .int(range.upperBound + 1)])
        #expect(result.text.hasPrefix("max_characters=\(range.upperBound + 1) is outside 1–\(range.upperBound); \(range.upperBound) was used.\nCut at \(range.upperBound) of 30000 characters;"))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)

        let wide = await Self.scripted(
            String(repeating: "😀", count: 40_000), arguments: ["max_characters": .int(range.upperBound)])
        #expect(wide.text.utf16.count <= ToolStandard.longestResult)
        #expect(wide.text.contains("Cut at "))
    }

    // MARK: A receipt of what was just done

    @Test("A closed tab's receipt is cut with the sentence for what cannot be read again")
    func closedReceiptIsCut() async {
        let title = String(repeating: "t", count: ToolCatalog.titleWidth + 250)
        let url = Fixtures.articleURL
        let store = FakeSafariStore(windows: [
            WindowInfo(
                id: 5, title: "Invented",
                tabs: [
                    TabSummary(id: TabID(windowID: 5, index: 1, url: url), title: title, url: url, isCurrent: true)
                ])
        ])
        let id = TabID(windowID: 5, index: 1, url: url).encoded
        let result = await Self.call(
            ToolCatalog.closeTabName, ["id": .string(id), "confirm": .bool(true)], store: store)
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Cut at \(ToolCatalog.titleWidth) of \(title.count) characters; the rest cannot be read again.\n\n"))
    }

    @Test("A URL opened that is longer than its width is clipped and announced")
    func openedReceiptIsClipped() async {
        let url = "https://example.com/" + String(repeating: "u", count: ToolCatalog.urlWidth)
        let result = await Self.call(ToolCatalog.openURLName, ["url": .string(url)])
        #expect(result.text.hasPrefix("URL is clipped to \(ToolCatalog.urlWidth) characters in each row. Read one in full with tab_get_text.\n\n"))
    }

    // MARK: History

    @Test("history_search pages at the store: the offset and limit go down, and the total comes back")
    func historyPagesAtTheStore() async {
        let store = Self.history.store(40)
        let result = await Self.call(
            ToolCatalog.historySearchName, ["limit": .int(10), "offset": .int(20)], store: store)
        #expect(store.historyQueries.last?.limit == 10)
        #expect(store.historyQueries.last?.offset == 20)
        #expect(result.text.hasPrefix("Showing 21–30 of 40 visits. Pass offset=30 for the next page.\n\n"))
    }

    @Test("A history page too wide to fit holds fewer rows and says where to resume")
    func widHistoryPageShrinks() async throws {
        let wide = String(repeating: "w", count: 2_000)
        let store = FakeSafariStore(
            history: (0..<100).map {
                HistoryEntry(
                    url: "https://example.com/\(Self.padded($0))-\(wide)", title: "visit-\(Self.padded($0))-",
                    visitedAt: Fixtures.date(2026, 8, 9, 12).addingTimeInterval(-Double($0) * 60),
                    visitCount: 1)
            })
        let result = await Self.call(
            ToolCatalog.historySearchName,
            ["limit": .int(ToolCatalog.historyLimitRange.upperBound)], store: store)
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        let shown = (0..<100).filter { result.text.contains("visit-\(Self.padded($0))-") }
        let last = try #require(shown.last)
        #expect(shown.first == 0 && shown.count < 100)
        #expect(result.text.hasPrefix("Showing 1–\(last + 1) of 100 visits. Pass offset=\(last + 1) for the next page.\n\n"))
    }

    @Test("A date range end is inclusive at the precision written")
    func rangeEndsAreInclusive() async throws {
        func upperBound(_ written: String) async throws -> Date {
            let store = FakeSafariStore()
            let result = await Self.call(
                ToolCatalog.historySearchName, ["to_date": .string(written)], store: store)
            #expect(!result.isError, "\(written)")
            return try #require(store.historyQueries.last?.to)
        }
        #expect(try await upperBound("2026-08-12") == Fixtures.date(2026, 8, 13))
        #expect(try await upperBound("2026-08-12T09:00") == Fixtures.date(2026, 8, 12, 9, 1))
        #expect(try await upperBound("2026-08-12T09:00:30") == Fixtures.date(2026, 8, 12, 9, 0).addingTimeInterval(31))
        #expect(try await upperBound("2026-08-12T09:00:00+02:00") == Fixtures.date(2026, 8, 12, 9, 0).addingTimeInterval(1))
    }

    @Test("A day on the last day of a range includes visits made that evening")
    func lastDayIncludesTheEvening() async {
        let store = FakeSafariStore()
        let result = await Self.call(
            ToolCatalog.historySearchName,
            ["from_date": .string("2026-08-09"), "to_date": .string("2026-08-09")], store: store)
        #expect(result.text.contains("Tide tables for August"))
    }

    @Test("Dates that do not exist, or end before they start, are refused with the form expected")
    func impossibleDates() async {
        let refused = [
            "2026-02-30", "2026-13-01", "2026-04-31", "2025-02-29", "2026-03-29T02:30",
            "2026-08-12T24:00", "2026-08-12T09:60", "2026-08-12T09:00:61", "2026-02-30T09:00:00+01:00",
            "yesterday", "2026-08-12T09:00-05:00", "2026-08-12T09:00T10:00",
        ]
        for written in refused {
            let store = FakeSafariStore()
            let result = await Self.call(ToolCatalog.historySearchName, ["from_date": .string(written)], store: store)
            #expect(result.isError, "\(written)")
            #expect(result.text.contains("2026-08-12T09:00:00+02:00"), "\(written)")
            #expect(store.historyQueries.isEmpty, "\(written)")
        }
        #expect(!(await Self.call(ToolCatalog.historySearchName, ["from_date": .string("2024-02-29")])).isError)

        let backwards = await Self.call(
            ToolCatalog.historySearchName,
            ["from_date": .string("2026-08-10"), "to_date": .string("2026-08-09")])
        #expect(backwards.isError)
        #expect(backwards.text.contains("to_date"))
    }

    // MARK: Arguments

    @Test("An argument the schema does not list is refused, with the names that are allowed")
    func unknownArgumentsAreRefused() async {
        let renamed = await Self.call(ToolCatalog.historySearchName, ["from": .string("2026-08-01")])
        #expect(renamed.isError)
        #expect(renamed.text.contains("'from'"))
        #expect(renamed.text.contains("from_date, limit, offset, query, to_date"))

        let none = await Self.call(ToolCatalog.statusName, ["limit": .int(1)])
        #expect(none.isError)
        #expect(none.text.contains("takes no arguments"))

        let several = await Self.call(ToolCatalog.tabsListName, ["a": .int(1), "b": .int(2), "c": .int(3)])
        #expect(several.text.contains("(and 2 more)"))
    }

    @Test("A wrong type is refused with the form expected, and null means not given")
    func wrongTypes() async {
        let word = await Self.call(ToolCatalog.tabsListName, ["limit": .string("many")])
        #expect(word.isError && word.text.contains("a whole number was expected"))
        let fraction = await Self.call(ToolCatalog.tabsListName, ["limit": .double(2.5)])
        #expect(fraction.isError && fraction.text.contains("a whole number was expected"))
        let number = await Self.call(ToolCatalog.historySearchName, ["query": .int(3)])
        #expect(number.isError && number.text.contains("text was expected"))
        let flag = await Self.call(ToolCatalog.closeTabName, ["id": .string("x"), "confirm": .string("yes")])
        #expect(flag.isError)
        let null = await Self.call(ToolCatalog.tabsListName, ["limit": .null, "offset": .null])
        #expect(!null.isError)
    }

    @Test("A long argument is repeated in an error only in part")
    func errorsEchoLittle() async {
        let long = String(repeating: "z", count: 5_000)
        let results = [
            await Self.call(ToolCatalog.tabTextName, ["id": .string(long)]),
            await Self.call(ToolCatalog.historySearchName, ["from_date": .string(long)]),
            await Self.call(ToolCatalog.openURLName, ["url": .string("ftp://" + long)]),
            await Self.call(long),
            await Self.call(ToolCatalog.tabsListName, [long: .int(1)]),
        ]
        for result in results {
            #expect(result.isError)
            #expect(result.text.utf16.count < 1_000)
        }
    }

    // MARK: Time

    @Test("A read that does not answer in time is abandoned, and says nothing was changed")
    func readTimesOut() async {
        let store = FakeSafariStore()
        store.windowsDelay = .seconds(30)
        let started = ContinuousClock.now
        let result = await Self.call(ToolCatalog.tabsListName, store: store, deadline: .milliseconds(200))
        #expect(result.isError)
        #expect(result.text.contains("nothing was changed"))
        #expect(!result.text.contains("may still have been made"))
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test("A write that does not answer in time says the change may still have been made")
    func writeTimesOut() async {
        let store = FakeSafariStore()
        store.windowsDelay = .seconds(30)
        let id = TabID(windowID: 101, index: 1, url: Fixtures.articleURL).encoded
        let result = await Self.call(
            ToolCatalog.closeTabName, ["id": .string(id), "confirm": .bool(true)], store: store,
            deadline: .milliseconds(200))
        #expect(result.isError)
        #expect(result.text.contains("may still have been made"))
    }

    @Test("The deadline of a call, and Safari's own wait, sit inside the time limit")
    func deadlinesAreInsideTheLimit() {
        #expect(ToolCatalog.callDeadline < ToolStandard.timeLimit)
        #expect(ToolCatalog.eventTimeoutSeconds < ToolCatalog.callDeadline.components.seconds)
    }

    // MARK: The texts the model reads

    @Test("No instructions or description is longer than a client reads")
    func textsAreWithinTheLimit() {
        var configuration = Configuration()
        configuration.allowsJavaScript = true
        configuration.allowsPageSource = true
        for configuration in [Configuration(), configuration] {
            #expect(
                ToolStandard.overlongTexts(
                    instructions: SafariMCPServer.instructions, catalog: ToolCatalog.all(configuration)
                ).isEmpty)
        }
    }

    @Test("Every limit argument is advertised with the range the code enforces")
    func schemasMatchTheCode() throws {
        let expected: [String: (arguments: [String: ClosedRange<Int>], defaults: [String: Int])] = [
            ToolCatalog.tabsListName: (
                ["limit": ToolCatalog.tabLimitRange, "offset": ToolCatalog.offsetRange],
                ["limit": ToolCatalog.defaultTabLimit, "offset": 0]),
            ToolCatalog.bookmarksListName: (
                ["limit": ToolCatalog.bookmarkLimitRange, "offset": ToolCatalog.offsetRange],
                ["limit": ToolCatalog.defaultBookmarkLimit, "offset": 0]),
            ToolCatalog.historySearchName: (
                ["limit": ToolCatalog.historyLimitRange, "offset": ToolCatalog.offsetRange],
                ["limit": ToolCatalog.defaultHistoryLimit, "offset": 0]),
            ToolCatalog.tabTextName: (
                [
                    "character_offset": ToolCatalog.characterOffsetRange,
                    "max_characters": ToolCatalog.maxCharactersRange,
                ], ["character_offset": 0, "max_characters": ToolCatalog.defaultMaxCharacters]),
            ToolCatalog.tabSourceName: (
                [
                    "character_offset": ToolCatalog.characterOffsetRange,
                    "max_characters": ToolCatalog.maxCharactersRange,
                ], ["character_offset": 0, "max_characters": ToolCatalog.defaultMaxCharacters]),
            ToolCatalog.runJavaScriptName: (
                ["max_characters": ToolCatalog.maxCharactersRange],
                ["max_characters": ToolCatalog.defaultMaxCharacters]),
        ]
        for tool in ToolCatalog.all() {
            guard let (arguments, defaults) = expected[tool.name] else { continue }
            guard case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"]
            else { Issue.record("\(tool.name) has no schema"); continue }
            for (name, range) in arguments {
                guard case .object(let property)? = properties[name] else {
                    Issue.record("\(tool.name) lacks \(name)"); continue
                }
                #expect(property["minimum"]?.intValue == range.lowerBound, "\(tool.name).\(name)")
                #expect(property["maximum"]?.intValue == range.upperBound, "\(tool.name).\(name)")
                #expect(property["default"]?.intValue == defaults[name], "\(tool.name).\(name)")
            }
        }
        for tool in [ToolCatalog.tabsList, ToolCatalog.bookmarksList, ToolCatalog.historySearch] {
            #expect(tool.description?.contains("up to") == true)
        }
        #expect(ToolCatalog.tabsList.description?.contains("\(ToolCatalog.tabLimitRange.upperBound)") == true)
        #expect(ToolCatalog.bookmarksList.description?.contains("\(ToolCatalog.bookmarkLimitRange.upperBound)") == true)
        #expect(ToolCatalog.historySearch.description?.contains("\(ToolCatalog.historyLimitRange.upperBound)") == true)
        #expect(SafariMCPServer.instructions.contains("\(ToolCatalog.defaultMaxCharacters)"))
    }

    @Test("The README and the manifest state no figure that the code could change")
    func proseHoldsNoFigures() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let readme = try String(contentsOf: root.appending(path: "README.md"), encoding: .utf8)
        let manifestText = try String(contentsOf: root.appending(path: "extension/manifest.json"), encoding: .utf8)
        let figure = try Regex(#"\d[\d,]*\s+(characters|tabs|bookmarks|visits|seconds)"#)
        #expect(readme.firstMatch(of: figure) == nil)
        #expect(manifestText.firstMatch(of: figure) == nil)

        let manifest = try #require(
            try JSONSerialization.jsonObject(with: Data(manifestText.utf8)) as? [String: Any])
        let listed = (manifest["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        #expect(listed == ToolCatalog.all().map(\.name))
    }
}
