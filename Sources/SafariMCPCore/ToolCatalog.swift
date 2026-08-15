import Foundation
import MCP

/// The catalogue is the authorisation surface: a tool that is not listed here cannot
/// be called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop.
///
/// Reads carry no verb. The three writes are named for the browser command they send —
/// `open_url`, `close_tab`, `reading_list_add` — rather than taking the sibling servers'
/// `create_`/`update_`/`delete_` prefixes, because none of them is CRUD over a stored
/// record: nothing here has a lifecycle to create or delete. The rule the prefixes exist
/// to serve is kept all the same: the destructive one says `close`, and it is the only
/// tool in the list that requires `confirm=true`.
///
/// **`do JavaScript` is deliberately absent**, and its absence is a decision rather than
/// an omission — see the README. Safari's dictionary offers it; this server does not, and
/// the Objective-C bridge does not even declare the selector.
public enum ToolCatalog {

    /// Names are constants rather than being read back off a `Tool`, because a tool whose
    /// schema depends on the configuration has to be built as a function and its name
    /// would then have nowhere stable to live.
    public static let statusName = "safari_status"
    public static let tabsListName = "tabs_list"
    public static let tabTextName = "tab_get_text"
    public static let tabSourceName = "tab_get_source"
    public static let openURLName = "open_url"
    public static let closeTabName = "close_tab"
    public static let readingListAddName = "reading_list_add"
    public static let bookmarksListName = "bookmarks_list"
    public static let historySearchName = "history_search"

    /// `tabSource` alone is built from the live configuration: whether it is enabled is
    /// the one thing left in `Configuration` that varies per instance. Every other
    /// description states a fixed constant, the same in every build.
    public static func all(_ configuration: Configuration = Configuration()) -> [Tool] {
        [
            status, tabsList, tabText, tabSource(configuration), openURL,
            closeTab, readingListAdd, bookmarksList, historySearch,
        ]
    }

    // MARK: Schema helpers

    private static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    /// `type` is always a single string, never `["string", "null"]`. Claude Desktop's
    /// schema sanitiser drops a property outright when its `type` is a union and hands
    /// the model a bare `{}` in its place; an array argument is then serialised to a
    /// string and rejected on arrival. Omit an optional field rather than passing null.
    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integer(_ description: String, minimum: Int, maximum: Int, default def: Int)
        -> Value
    {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum), "default": .int(def),
        ])
    }

    private static let dateHelp = """
        Accepts 2026-08-12 (whole day), 2026-08-12T09:00 (local time), or \
        2026-08-12T09:00:00+02:00 (explicit offset).
        """

    private static let tabIDProperty = string(
        """
        Opaque tab id from tabs_list. It names a position in a window and carries a \
        fingerprint of the page it was made for, so it stops being valid when tabs are \
        reordered or the tab navigates elsewhere.
        """)

    // MARK: Reads

    static let status = Tool(
        name: statusName,
        title: "Safari permission status",
        description: """
            Reports whether Safari is running, whether this server may control it, and \
            whether the bookmarks and history files on disk can be read. Opens no page and \
            reads no tab.

            Use it when another Safari tool fails, or when setting the server up. The two \
            permissions are unrelated: controlling Safari can be allowed while bookmarks \
            and history stay blocked behind Full Disk Access.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let tabsList = Tool(
        name: tabsListName,
        title: "List open tabs",
        description: """
            Lists every Safari window and every tab in it, with the page title, the URL and \
            the id needed to read or close that tab. Marks which tab is frontmost in each \
            window.

            Call this before tab_get_text, tab_get_source or close_tab — ids come from here \
            and go stale as soon as tabs move. Safari must already be running; this server \
            will not launch it.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let tabText = Tool(
        name: tabTextName,
        title: "Read an open tab's text",
        description: """
            Returns the rendered text of a page that is already open in Safari — what \
            the tab is displaying, not what a fresh request for that URL would return. \
            No network fetch happens, so a page behind a login or a paywall reads \
            exactly as the person sees it.

            One tab per call, cut at \(Configuration.pageCharacterLimit) characters, \
            because a page can run to megabytes. Needs an id from tabs_list.
            """,
        inputSchema: object(properties: ["id": tabIDProperty], required: ["id"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static func tabSource(_ configuration: Configuration) -> Tool {
        Tool(
            name: tabSourceName,
            title: "Read an open tab's HTML",
            description: """
                Returns the raw HTML of a page already open in Safari. \
                \(configuration.allowsPageSource
                    ? "Enabled in this extension's settings."
                    : "SWITCHED OFF in this extension's settings — every call fails until it is turned on.")

                Prefer tab_get_text: it answers almost every question about a page and \
                carries none of the inline scripts, tracking markup or embedded tokens that \
                the source does. Reach for source only when the markup itself is the \
                question — a meta tag, a link's href, a structured-data block.

                Cut at \(Configuration.pageCharacterLimit) characters. Needs an id from \
                tabs_list.
                """,
            inputSchema: object(properties: ["id": tabIDProperty], required: ["id"]),
            annotations: .init(
                readOnlyHint: true, destructiveHint: false, idempotentHint: true,
                openWorldHint: false)
        )
    }

    static let bookmarksList = Tool(
        name: bookmarksListName,
        title: "List bookmarks",
        description: """
            Lists saved bookmarks with their title, URL and the folder path each sits \
            in, optionally narrowed to one folder.

            Reads ~/Library/Safari/Bookmarks.plist, which needs Full Disk Access. \
            Without that grant the call fails with instructions rather than returning \
            an empty list — check safari_status first if in doubt. The Reading List is \
            not included: it is a separate store this server cannot read back.
            """,
        inputSchema: object(properties: [
            "folder": string(
                """
                Optional folder path to narrow to, matched case-insensitively as a \
                prefix — "News" matches "News" and "News/Spain". Omit for all of them.
                """),
            "limit": integer(
                "Maximum number of bookmarks to return.",
                minimum: Configuration.searchLimitRange.lowerBound,
                maximum: Configuration.searchLimitRange.upperBound,
                default: Configuration.searchLimit),
        ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let historySearch = Tool(
        name: historySearchName,
        title: "Search browsing history",
        description: """
            Finds pages Safari has visited, matching the text against the URL and the \
            page title and bounded by a date range. Newest first.

            Reads ~/Library/Safari/History.db, which needs Full Disk Access. Without \
            that grant the call fails with instructions rather than returning an empty \
            list. The text of a visited page is not stored anywhere — only its URL, its \
            title and when it was seen — so a question about what a page said needs the \
            page open and tab_get_text.
            """,
        inputSchema: object(properties: [
            "query": string(
                "Optional text to match against the URL and the page title."),
            "from": string("Oldest visit to include. \(dateHelp)"),
            "to": string("Newest visit to include. \(dateHelp)"),
            "limit": integer(
                "Maximum number of visits to return.",
                minimum: Configuration.searchLimitRange.lowerBound,
                maximum: Configuration.searchLimitRange.upperBound,
                default: Configuration.searchLimit),
        ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    // MARK: Writes

    static let openURL = Tool(
        name: openURLName,
        title: "Open a URL",
        description: """
            Opens a URL in a new Safari tab, in the frontmost window, and returns the id of \
            the tab it made. Safari must already be running.

            Only http and https are opened. A javascript: URL is refused — it is the \
            do-JavaScript command by another route, and this server does not run code in \
            the person's browsing session.
            """,
        inputSchema: object(
            properties: [
                "url": string("The page to open. A bare host is treated as https.")
            ],
            required: ["url"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
    )

    static let closeTab = Tool(
        name: closeTabName,
        title: "Close a tab",
        description: """
            Closes one open tab. Requires confirm=true and returns the title and URL of what \
            it closed.

            CANNOT BE UNDONE from here. A closed tab takes its scroll position, its back \
            history and anything typed into the page with it; "Reopen Last Closed Tab" is a \
            menu gesture only the person at the keyboard can make. Say which tab you mean \
            and get their agreement first.

            Refuses an id that no longer points at the page it was made for, so reordered \
            tabs cannot make it close the wrong one.
            """,
        inputSchema: object(
            properties: [
                "id": tabIDProperty,
                "confirm": .object([
                    "type": .string("boolean"),
                    "description": .string("Must be true. Without it the call is refused."),
                ]),
            ],
            required: ["id", "confirm"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )

    static let readingListAdd = Tool(
        name: readingListAddName,
        title: "Add to the Reading List",
        description: """
            Saves a URL to Safari's Reading List, optionally with a title and a line of \
            preview text.

            Safari's dictionary cannot read the Reading List back, so this cannot report \
            what is already saved and cannot tell a duplicate from a new item — the same \
            URL added twice is accepted twice. Only http and https are saved.
            """,
        inputSchema: object(
            properties: [
                "url": string("The page to save. A bare host is treated as https."),
                "title": string("Optional title. Safari uses the page's own if omitted."),
                "preview_text": string(
                    "Optional preview line, usually the first sentences of the article."),
            ],
            required: ["url"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
    )
}
