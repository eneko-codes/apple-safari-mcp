import Foundation

public enum SafariMCPServer {

    public static let name = "apple-safari-mcp"
    public static let version = "2.0.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: the id workflow, the two unrelated permissions, and what reading a tab
    /// actually means.
    public static let instructions = """
        Access to the macOS Safari app.

        Safari has no framework an external process can use to read its tabs, so this \
        server drives Safari through Apple events. Safari must already be running; this \
        server will not launch it.

        Workflow: tabs_list first, then use the id it returns. A tab id names a position \
        in a window — Safari gives a tab no identifier of its own — so it goes stale the \
        moment tabs are closed or reordered. Ids carry a fingerprint of the page they were \
        made for and a call is refused rather than acted on when it no longer matches.

        tab_get_text returns the page AS RENDERED IN THAT TAB. No network request is made, \
        so it reads what the person sees: logged-in dashboards, paywalled articles, \
        anything already on screen. Treat it as the person's own screen, not as a public \
        web page. tab_get_source returns raw HTML and is off unless it was switched on in \
        the extension's settings.

        run_javascript runs code inside a tab you name, exactly as the page's own script \
        could — no restriction on which tab, so choose it as deliberately as the script \
        itself. Off unless switched on in the extension's settings, and separately gated \
        by Safari's own "Allow JavaScript from Apple Events" developer setting, off by \
        default on every Mac. A javascript: URL passed to open_url is still refused: it \
        is the same command reached by a different route, and run_javascript is the one \
        way in.

        LISTS COME IN PAGES. tabs_list, bookmarks_list and history_search return one page \
        of rows (\(ToolCatalog.defaultTabLimit), \(ToolCatalog.defaultBookmarkLimit) and \
        \(ToolCatalog.defaultHistoryLimit) by default). When rows exist that a result does \
        not hold, its first lines say how many there are and the offset of the next page: \
        pass limit and offset. A long page or HTML source is read one window at a time: \
        the first \(ToolCatalog.defaultMaxCharacters) characters of tab_get_text and \
        tab_get_source come back, and the first lines give the character_offset for the \
        rest. A number outside its range is moved to the nearest allowed value and the \
        first lines say which one was used; an argument a tool does not list is refused.

        A script's result is cut at max_characters. The rest cannot be read again, because \
        the script cannot safely be run twice: return less from it.

        EVERY CALL IS BOUNDED. A call that has not finished after \
        \(ToolCatalog.callDeadline.components.seconds) seconds is abandoned and answered \
        with an error saying so. For open_url, close_tab, reading_list_add and \
        run_javascript that error says the change may still have been made.

        close_tab is irreversible from here: a closed tab takes its scroll position, its \
        back history and anything typed into the page with it. It requires confirm=true.

        Bookmarks and history are files under ~/Library/Safari, not Apple events. They \
        need Full Disk Access, a grant given by hand in System Settings that this server \
        cannot request. When it is missing those two tools fail with instructions; \
        everything else keeps working. safari_status reports both permissions separately.

        This server exposes Safari's reachable capability. What may be used at any moment \
        is decided by the permission switches in the client, not by this code.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing
    /// in this function contacts Safari by itself.
    public static func run(
        store: any SafariStore = BridgeSafariStore(),
        configuration: Configuration = Configuration()
    ) async {
        Diagnostics.started(version: version)
        await serveStandardStreams(
            handler: handler(
                tools: SafariTools(store: store, configuration: configuration),
                configuration: configuration))
    }

    public static func handler(tools: SafariTools, configuration: Configuration) -> MCPHandler {
        MCPHandler(
            name: name, version: version, instructions: instructions,
            catalog: ToolCatalog.all(configuration), tools: tools)
    }
}
