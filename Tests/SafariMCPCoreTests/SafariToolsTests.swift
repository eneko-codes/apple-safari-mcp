import Foundation
import MCP
import Testing

@testable import SafariMCPCore

/// Drives the tool layer end to end against `FakeSafariStore`. No test here sends an
/// Apple event, so the suite runs with Safari closed, no Automation consent and no tab
/// on the owner's screen touched.
@Suite("Tool dispatch")
struct SafariToolsTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:],
        store: FakeSafariStore = FakeSafariStore(),
        configuration: Configuration = Configuration()
    ) async -> (text: String, isError: Bool) {
        let tools = SafariTools(
            store: store, calendar: Fixtures.calendar, configuration: configuration)
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text, _, _) = result.content.first else {
            return ("(no text content)", true)
        }
        return (text, result.isError ?? false)
    }

    /// The id of the first tab of the first fixture window.
    private var articleTabID: String {
        TabID(windowID: 101, index: 1, url: Fixtures.articleURL).encoded
    }

    // MARK: Catalogue

    @Test("Every tool has a unique name, title and description")
    func catalogueIsWellFormed() {
        let tools = ToolCatalog.all()
        let names = tools.map(\.name)
        #expect(names.count == Set(names).count)
        for tool in tools {
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
            #expect(tool.title?.isEmpty == false, "\(tool.name) has no title")
        }
    }

    /// Claude Desktop's schema sanitiser drops a property whose `type` is a union and
    /// hands the model a bare `{}` instead. The fault stays invisible until a caller
    /// happens to use that field.
    @Test("No property declares a union type")
    func noUnionTypesInSchemas() {
        for tool in ToolCatalog.all() {
            guard case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"]
            else { continue }
            for (property, definition) in properties {
                guard case .object(let fields) = definition else { continue }
                if case .array = fields["type"] {
                    Issue.record("\(tool.name).\(property) declares a union type")
                }
            }
        }
    }

    /// `run_javascript` is offered, but never without the caller having to say so twice:
    /// once in the extension's own settings, and once with `allowsJavaScript` on the
    /// configuration this catalogue is built from.
    @Test("run_javascript's description names the setting when it is off")
    func javaScriptDescriptionReflectsConfiguration() {
        let off = ToolCatalog.all(Configuration()).first { $0.name == ToolCatalog.runJavaScriptName }
        #expect(off?.description?.contains("SWITCHED OFF") == true)

        var configuration = Configuration()
        configuration.allowsJavaScript = true
        let on = ToolCatalog.all(configuration).first { $0.name == ToolCatalog.runJavaScriptName }
        #expect(on?.description?.contains("SWITCHED OFF") == false)
    }

    @Test("Only the tools that change something are marked as writes")
    func annotationsAreHonest() {
        let writes = [
            ToolCatalog.openURLName, ToolCatalog.closeTabName, ToolCatalog.readingListAddName,
            ToolCatalog.runJavaScriptName,
        ]
        for tool in ToolCatalog.all() {
            #expect(
                tool.annotations.readOnlyHint == !writes.contains(tool.name),
                "\(tool.name) is mis-annotated")
        }
    }

    // MARK: Availability

    @Test("A tool call is refused when Safari is not running")
    func refusesWhenNotRunning() async {
        let store = FakeSafariStore()
        store.state = .notRunning
        let (text, isError) = await call(ToolCatalog.tabsListName, store: store)
        #expect(isError)
        #expect(text.contains("running"))
    }

    /// macOS only raises the Automation dialog when a real Apple event is sent, so
    /// refusing this state would mean the dialog never appears and consent could never be
    /// granted at all.
    @Test("Ungranted consent does not block the call that would trigger the prompt")
    func consentNotGrantedStillProceeds() async {
        let store = FakeSafariStore()
        store.state = .consentNotGranted
        let (_, isError) = await call(ToolCatalog.tabsListName, store: store)
        #expect(!isError)
    }

    @Test("safari_status works while Safari is unreachable")
    func statusWorksWhenUnavailable() async {
        let store = FakeSafariStore()
        store.state = .automationDenied
        let (text, isError) = await call(ToolCatalog.statusName, store: store)
        #expect(!isError)
        #expect(!text.isEmpty)
    }

    // MARK: Tabs

    @Test("tabs_list reports every window and tab")
    func tabsAreListed() async {
        let (text, isError) = await call(ToolCatalog.tabsListName)
        #expect(!isError)
        #expect(text.contains("Tide tables for August"))
        #expect(text.contains("The manual"))
    }

    @Test("tab_get_text returns the rendered text of a tab")
    func tabTextIsReturned() async {
        let (text, isError) = await call(
            ToolCatalog.tabTextName, ["id": .string(articleTabID)])
        #expect(!isError)
        #expect(text.contains("High water"))
    }

    /// The guard the whole `TabID` design exists for. Safari addresses a tab by position,
    /// and positions shift when a tab is opened, closed or dragged — so an id also carries
    /// a fingerprint of the URL it was minted for, and a mismatch must refuse rather than
    /// quietly read whatever is sitting at that index now.
    @Test("A stale id refuses instead of reading whatever moved into that position")
    func staleTabIDIsRefused() async {
        let stale = TabID(
            windowID: 101, index: 1, url: "https://example.com/something-else").encoded
        let (text, isError) = await call(ToolCatalog.tabTextName, ["id": .string(stale)])
        #expect(isError)
        #expect(text.contains("tabs_list"))
    }

    @Test("An unparseable id is refused")
    func malformedTabIDIsRefused() async {
        let (_, isError) = await call(ToolCatalog.tabTextName, ["id": .string("not-an-id")])
        #expect(isError)
    }

    @Test("A page longer than the fixed ceiling is truncated and says so")
    func longPageIsTruncated() async {
        let store = FakeSafariStore()
        let pageLength = Configuration.pageCharacterLimit + 500
        store.pageText = [Fixtures.articleURL: String(repeating: "x", count: pageLength)]

        let (text, isError) = await call(
            ToolCatalog.tabTextName, ["id": .string(articleTabID)], store: store)
        #expect(!isError)
        #expect(text.count < pageLength)
    }

    // MARK: Writes

    @Test("open_url reaches the store with the URL it was given")
    func openURLPassesThrough() async {
        let store = FakeSafariStore()
        let (_, isError) = await call(
            ToolCatalog.openURLName, ["url": .string("https://example.com/new")], store: store)
        #expect(!isError)
        #expect(store.openedURLs == ["https://example.com/new"])
    }

    /// A closed tab with unsaved state is not recoverable, so the confirmation is not
    /// ceremony.
    @Test("close_tab without confirm=true closes nothing")
    func closeTabRequiresConfirmation() async {
        let store = FakeSafariStore()
        let (text, isError) = await call(
            ToolCatalog.closeTabName, ["id": .string(articleTabID)], store: store)
        #expect(isError)
        #expect(store.closedTabs.isEmpty)
        #expect(text.contains("confirm"))
    }

    @Test("close_tab with confirm=true closes exactly the tab addressed")
    func closeTabClosesOne() async {
        let store = FakeSafariStore()
        let (_, isError) = await call(
            ToolCatalog.closeTabName,
            ["id": .string(articleTabID), "confirm": .bool(true)], store: store)
        #expect(!isError)
        #expect(store.closedTabs.count == 1)
        #expect(store.closedTabs.first?.windowID == 101)
    }

    @Test("run_javascript fails while switched off, whatever the arguments")
    func runJavaScriptRefusedWhenDisabled() async {
        let store = FakeSafariStore()
        let (text, isError) = await call(
            ToolCatalog.runJavaScriptName,
            ["id": .string(articleTabID), "script": .string("1+1"), "confirm": .bool(true)],
            store: store, configuration: Configuration())
        #expect(isError)
        #expect(text.contains("Allow running JavaScript"))
        #expect(store.scriptsRun.isEmpty)
    }

    @Test("run_javascript without confirm=true runs nothing")
    func runJavaScriptRequiresConfirmation() async {
        var configuration = Configuration()
        configuration.allowsJavaScript = true
        let store = FakeSafariStore()
        let (text, isError) = await call(
            ToolCatalog.runJavaScriptName,
            ["id": .string(articleTabID), "script": .string("1+1")],
            store: store, configuration: configuration)
        #expect(isError)
        #expect(store.scriptsRun.isEmpty)
        #expect(text.contains("confirm"))
    }

    @Test("run_javascript with confirm=true runs the script in exactly the tab addressed")
    func runJavaScriptRunsOne() async {
        var configuration = Configuration()
        configuration.allowsJavaScript = true
        let store = FakeSafariStore()
        store.scriptResults["document.title"] = "Tide tables for August"
        let (text, isError) = await call(
            ToolCatalog.runJavaScriptName,
            [
                "id": .string(articleTabID), "script": .string("document.title"),
                "confirm": .bool(true),
            ],
            store: store, configuration: configuration)
        #expect(!isError)
        #expect(store.scriptsRun.count == 1)
        #expect(store.scriptsRun.first?.id.windowID == 101)
        #expect(store.scriptsRun.first?.script == "document.title")
        #expect(text.contains("Tide tables for August"))
    }

    @Test("run_javascript refuses a tab id that no longer matches, before confirmation is even checked")
    func runJavaScriptRefusesStaleTab() async {
        var configuration = Configuration()
        configuration.allowsJavaScript = true
        let store = FakeSafariStore()
        let staleID = TabID(windowID: 101, index: 1, url: "https://example.com/moved-on")
        let (text, isError) = await call(
            ToolCatalog.runJavaScriptName,
            ["id": .string(staleID.encoded), "script": .string("1+1"), "confirm": .bool(true)],
            store: store, configuration: configuration)
        #expect(isError)
        #expect(store.scriptsRun.isEmpty)
        #expect(text.contains("tabs_list"))
    }

    @Test("reading_list_add passes the URL through")
    func readingListAddPassesThrough() async {
        let store = FakeSafariStore()
        let (_, isError) = await call(
            ToolCatalog.readingListAddName,
            ["url": .string("https://example.com/later")], store: store)
        #expect(!isError)
        #expect(store.readingListItems.first?.url == "https://example.com/later")
    }

    // MARK: The Full Disk Access surface

    /// Bookmarks and history live in protected files. Without Full Disk Access this must
    /// say so — there is no plist key that asks for it, so an unexplained empty result
    /// would look like an empty browser.
    @Test("Blocked bookmarks and history explain the permission rather than returning nothing")
    func blockedLibraryExplainsItself() async {
        let store = FakeSafariStore()
        store.library = LibraryStatus(bookmarks: .blocked, history: .blocked)
        store.bookmarksFailure = .fullDiskAccessRequired(what: "Bookmarks", path: "/invented/Bookmarks.plist")
        store.historyFailure = .fullDiskAccessRequired(what: "History", path: "/invented/History.db")

        for tool in [ToolCatalog.bookmarksListName, ToolCatalog.historySearchName] {
            let (text, isError) = await call(tool, store: store)
            #expect(isError, "\(tool) should refuse when the library is blocked")
            #expect(text.contains("Full Disk Access"), "\(tool) should name the permission")
        }
    }

    @Test("bookmarks_list reports bookmarks when the library is readable")
    func bookmarksAreListed() async {
        let (text, isError) = await call(ToolCatalog.bookmarksListName)
        #expect(!isError)
        #expect(!text.isEmpty)
    }

    @Test("history_search pushes its filters down to the store")
    func historyPassesFilters() async {
        let store = FakeSafariStore()
        let (_, isError) = await call(
            ToolCatalog.historySearchName,
            ["query": .string("swift"), "from": .string("2026-08-01")], store: store)
        #expect(!isError)
        #expect(store.historyQueries.first?.query == "swift")
        #expect(store.historyQueries.first?.from != nil)
    }

    // MARK: Failure

    @Test("An unknown tool name is refused")
    func unknownToolIsRefused() async {
        let (_, isError) = await call("safari_close_everything")
        #expect(isError)
    }

    @Test("A store failure is reported rather than swallowed")
    func storeFailureIsReported() async {
        let store = FakeSafariStore()
        store.bookmarksFailure = .storeFailure("Safari stopped responding")
        let (text, isError) = await call(ToolCatalog.bookmarksListName, store: store)
        #expect(isError)
        #expect(text.contains("Safari"))
    }
}
