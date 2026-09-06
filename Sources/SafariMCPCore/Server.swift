import Foundation
import MCP

public enum SafariMCPServer {

    public static let name = "apple-safari-mcp"
    public static let version = "1.1.1"

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
    ) async throws {
        let tools = SafariTools(store: store, configuration: configuration)
        let server = Server(
            name: name,
            version: version,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.all(configuration)) }
        await server.withMethodHandler(CallTool.self) { await tools.handle($0) }

        // The default StdioTransport logger is a no-op handler. Leave it that way: a
        // logger writing to stdout would interleave with the JSON-RPC stream and break
        // every response after the first log line.
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
