import Foundation
import SafariBridge

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
/// **`run_javascript` carries no domain restriction** — see the README. Safari's own `do
/// JavaScript` runs in whatever tab it targets, and this server does not narrow that: the
/// tool is off by default, gated by `allowsJavaScript` the same way `tab_get_source` is
/// gated, and its description says plainly what it can do once it is on.
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
    public static let runJavaScriptName = "run_javascript"

    // Pages. Each maximum is a number of rows of ordinary width that fits
    // `ToolStandard.longestResult` with room to spare, and each default makes a call with no
    // argument about `ToolStandard.usualPage` or less. `BoundsTests` renders a full page of
    // the widest ordinary rows of every listing to hold both to that.
    public static let offsetRange = 0...10_000_000
    public static let tabLimitRange = 1...50
    public static let defaultTabLimit = 15
    public static let bookmarkLimitRange = 1...100
    public static let defaultBookmarkLimit = 25
    public static let historyLimitRange = 1...100
    public static let defaultHistoryLimit = 25

    /// A tab's title and URL are clipped to these widths in `tabs_list`, where fifty rows
    /// have to fit one result; `tab_get_text` and `tab_get_source` show both in full.
    public static let titleWidth = 150
    public static let urlWidth = 300

    /// The window on one long text. The maximum is half the longest result, so a window of
    /// ordinary text leaves room for the rest of the answer, and `ToolStandard.fitting`
    /// shrinks one whose characters take more UTF-16 units than that.
    public static let characterOffsetRange = 0...100_000_000
    public static let maxCharactersRange = 1...(ToolStandard.longestResult / 2)
    public static let defaultMaxCharacters = ToolStandard.usualPage

    /// How long one call may take before it is abandoned. Safari's own wait for a reply to
    /// one Apple event is `SafariBridgeEventTimeoutSeconds`, shorter by a margin, so a call
    /// that is stuck on Safari ends with Safari's answer and not with ours. Both sit well
    /// inside `ToolStandard.timeLimit`.
    public static let eventTimeoutSeconds = Int(SafariBridgeEventTimeoutSeconds)
    public static let callDeadline = Duration.seconds(eventTimeoutSeconds + 10)

    /// The longest piece of a failure's own wording that an error repeats.
    public static let failureDetailWidth = 1_000

    /// The tools that change something, whose timeout error must not claim nothing happened.
    static let writeNames: Set<String> = [
        openURLName, closeTabName, readingListAddName, runJavaScriptName,
    ]

    /// The argument names a tool's schema lists.
    static func argumentNames(of toolName: String, _ configuration: Configuration) -> [String] {
        guard let tool = all(configuration).first(where: { $0.name == toolName }),
            case .object(let schema) = tool.inputSchema,
            case .object(let properties)? = schema["properties"]
        else { return [] }
        return properties.keys.sorted()
    }

    /// `tabSource` alone is built from the live configuration: whether it is enabled is
    /// the one thing left in `Configuration` that varies per instance. Every other
    /// description states a fixed constant, the same in every build.
    public static func all(_ configuration: Configuration = Configuration()) -> [Tool] {
        [
            status, tabsList, tabText, tabSource(configuration), openURL,
            closeTab, readingListAdd, bookmarksList, historySearch,
            runJavaScript(configuration),
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

    private static func integer(_ description: String, range: ClosedRange<Int>, default def: Int)
        -> Value
    {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(range.lowerBound), "maximum": .int(range.upperBound),
            "default": .int(def),
        ])
    }

    private static func limit(_ things: String, range: ClosedRange<Int>, default def: Int) -> Value {
        integer("Maximum number of \(things) in one page.", range: range, default: def)
    }

    private static let offset = integer(
        """
        Number of rows to skip. A result that does not hold every row says, in its first \
        lines, the offset to pass for the next page.
        """, range: offsetRange, default: 0)

    private static let characterOffset = integer(
        """
        Number of characters to skip. A result that does not hold the whole text says, in \
        its first lines, the character_offset to pass for the rest.
        """, range: characterOffsetRange, default: 0)

    private static let maxCharacters = integer(
        "Most characters of the text to return in one call.", range: maxCharactersRange,
        default: defaultMaxCharacters)

    private static let dateHelp = """
        Accepts 2026-08-12 (whole day), 2026-08-12T09:00 (local time), or \
        2026-08-12T09:00:00+02:00 (explicit offset). A date that does not exist is refused.
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
            Lists the open tabs, \(defaultTabLimit) to a page, grouped by window, with the \
            page title, the URL and the id needed to read or close that tab. Marks which tab \
            is frontmost in each window. Ordered by window id, then by position from the \
            left. When more tabs exist than the page holds, the first lines of the result \
            say how many there are and the offset of the next page: pass limit (up to \
            \(tabLimitRange.upperBound)) and offset for the rest. A title or URL longer than \
            \(titleWidth) or \(urlWidth) characters is clipped, and a first line says so: \
            tab_get_text shows both in full.

            Call this before tab_get_text, tab_get_source or close_tab — ids come from here \
            and go stale as soon as tabs move. Safari must already be running; this server \
            will not launch it.
            """,
        inputSchema: object(properties: [
            "limit": limit("tabs", range: tabLimitRange, default: defaultTabLimit),
            "offset": offset,
        ]),
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

            One tab per call, and the first \(defaultMaxCharacters) characters of its text \
            unless asked for more, because a page can run to megabytes. When the page is \
            longer, the first lines of the result say how many characters it has and the \
            character_offset to pass for the rest; max_characters (up to \
            \(maxCharactersRange.upperBound)) sets the size of a window. The title and URL \
            are shown in full. Needs an id from tabs_list.
            """,
        inputSchema: object(
            properties: [
                "id": tabIDProperty, "character_offset": characterOffset,
                "max_characters": maxCharacters,
            ], required: ["id"]),
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

                Returns the first \(defaultMaxCharacters) characters unless asked for more; \
                when the source is longer, the first lines of the result say how many \
                characters it has and the character_offset to pass for the rest, and \
                max_characters (up to \(maxCharactersRange.upperBound)) sets the size of a \
                window. Needs an id from tabs_list.
                """,
            inputSchema: object(
                properties: [
                    "id": tabIDProperty, "character_offset": characterOffset,
                    "max_characters": maxCharacters,
                ], required: ["id"]),
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
            in, optionally narrowed to one folder, \(defaultBookmarkLimit) to a page, in the \
            order of Safari's bookmark tree. When more match than the page holds, the first \
            lines of the result say how many there are and the offset of the next page: \
            pass limit (up to \(bookmarkLimitRange.upperBound)) and offset for the rest.

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
            "limit": limit("bookmarks", range: bookmarkLimitRange, default: defaultBookmarkLimit),
            "offset": offset,
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
            page title and bounded by a date range, \(defaultHistoryLimit) to a page, newest \
            first. When more match than the page holds, the first lines of the result say \
            how many there are and the offset of the next page: pass limit (up to \
            \(historyLimitRange.upperBound)) and offset for the rest.

            Reads ~/Library/Safari/History.db, which needs Full Disk Access. Without \
            that grant the call fails with instructions rather than returning an empty \
            list. The text of a visited page is not stored anywhere — only its URL, its \
            title and when it was seen — so a question about what a page said needs the \
            page open and tab_get_text.
            """,
        inputSchema: object(properties: [
            "query": string(
                "Optional text to match against the URL and the page title."),
            "from_date": string("Oldest visit to include. \(dateHelp)"),
            "to_date": string(
                "Newest visit to include, inclusive at the precision written: a bare day covers that whole day. \(dateHelp)"),
            "limit": limit("visits", range: historyLimitRange, default: defaultHistoryLimit),
            "offset": offset,
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

            Only http and https are opened. A javascript: URL is refused: it is the \
            do-JavaScript command reached through a URL instead of a tab id and a script \
            argument. run_javascript is the tool for running code, against a tab already \
            open.
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

    static func runJavaScript(_ configuration: Configuration) -> Tool {
        Tool(
            name: runJavaScriptName,
            title: "Run JavaScript in an open tab",
            description: """
                Runs JavaScript inside a tab already open in Safari and returns what it \
                evaluated to. \
                \(configuration.allowsJavaScript
                    ? "Enabled in this extension's settings."
                    : "SWITCHED OFF in this extension's settings — every call fails until it is turned on.")

                This is full page access, exactly as if the page's own script had run: it \
                can read whatever the page can read and do whatever a click on the page \
                could do — fill and submit a form, follow a link, read a value out of the \
                DOM. Nothing here restricts which tab: it runs in the session that tab \
                holds, signed in or not, so choose the tab as deliberately as the script \
                itself. Requires confirm=true, because a submitted form or a followed \
                link is not undone by closing the tab afterwards.

                Also needs Safari's own "Allow JavaScript from Apple Events" developer \
                setting — Safari → Settings → Advanced → Show features for web developers \
                → Develop menu — which is off by default on every Mac. A call fails with \
                that instruction until it is turned on once, by hand.

                Needs an id from tabs_list. Returns the result as text: a string as \
                itself, an object or array as JSON, and "(no value)" for a script that \
                returned nothing. Only the first \(defaultMaxCharacters) characters of the \
                result are returned unless max_characters (up to \
                \(maxCharactersRange.upperBound)) asks for more; the rest of a longer result \
                cannot be read again without running the script again, so return less \
                from the script or ask for more before running it.
                """,
            inputSchema: object(
                properties: [
                    "id": tabIDProperty,
                    "script": string("The JavaScript to run, evaluated as the body of a function."),
                    "max_characters": maxCharacters,
                    "confirm": .object([
                        "type": .string("boolean"),
                        "description": .string("Must be true. Without it the call is refused."),
                    ]),
                ],
                required: ["id", "script", "confirm"]),
            annotations: .init(
                readOnlyHint: false, destructiveHint: true, idempotentHint: false,
                openWorldHint: true)
        )
    }
}
