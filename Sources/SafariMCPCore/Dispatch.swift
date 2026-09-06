import Foundation
import MCP

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never sends an Apple event and never opens a file — everything goes through
/// `SafariStore`, which is what lets the tests drive every branch below against an
/// in-memory double with Safari closed and no permission granted.
public struct SafariTools: Sendable {
    private let store: any SafariStore
    private let calendar: Calendar
    private let configuration: Configuration
    private let format: Format

    public init(
        store: any SafariStore,
        calendar: Calendar = .current,
        configuration: Configuration = Configuration()
    ) {
        self.store = store
        self.calendar = calendar
        self.configuration = configuration
        self.format = Format(calendar: calendar)
    }

    public func handle(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            let text = try await run(parameters)
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let error as ToolError {
            return .init(
                content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(
                content: [
                    .text(
                        text: ToolError.storeFailure(error.localizedDescription).message,
                        annotations: nil, _meta: nil)
                ], isError: true)
        }
    }

    private func run(_ parameters: CallTool.Parameters) async throws -> String {
        let arguments = Arguments(parameters.arguments, calendar: calendar)

        if parameters.name == ToolCatalog.statusName {
            return format.status(
                store.availability(), library: store.libraryStatus(),
                binaryPath: Self.binaryPath, configuration: configuration)
        }

        // Bookmarks and history never touch Safari, so they must not be gated on whether
        // Safari is running. They have their own gate, and it is on the disk.
        switch parameters.name {
        case ToolCatalog.bookmarksListName:
            return try await bookmarks(arguments)
        case ToolCatalog.historySearchName:
            return try await history(arguments)
        default:
            break
        }

        try requireSafari()

        switch parameters.name {
        case ToolCatalog.tabsListName:
            return format.windowList(try await store.windows())

        case ToolCatalog.tabTextName:
            return try await tabContent(arguments, kind: .text)

        case ToolCatalog.tabSourceName:
            guard configuration.allowsPageSource else { throw ToolError.pageSourceDisabled }
            return try await tabContent(arguments, kind: .source)

        case ToolCatalog.openURLName:
            return format.opened(try await store.openURL(try arguments.webURL("url")))

        case ToolCatalog.closeTabName:
            return try await closeTab(arguments)

        case ToolCatalog.readingListAddName:
            return try await addToReadingList(arguments)

        case ToolCatalog.runJavaScriptName:
            guard configuration.allowsJavaScript else { throw ToolError.javascriptDisabled }
            return try await runJavaScript(arguments)

        default:
            throw ToolError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
        }
    }

    private func requireSafari() throws {
        let state = store.availability()
        guard !state.blocksCalls else { throw ToolError.notAvailable(state) }
    }

    // MARK: Tabs

    /// Checks that the id still names the page it was minted for, and returns the tab as
    /// it is now.
    ///
    /// This is the guard the whole `TabID` design exists for. Safari gives a tab no
    /// identifier of its own — only its position from the left — so an id minted before a
    /// tab was closed or dragged now addresses a different page. Verifying before acting
    /// is what stops `close_tab` from closing the neighbour of the tab that was meant, and
    /// it lives here rather than in the store so the tests can reach it.
    private func verified(_ id: TabID) async throws -> TabSummary {
        let live = try await store.tabSummary(id)
        guard id.matches(url: live.url) else {
            throw ToolError.tabChanged(id: id.encoded, url: live.url)
        }
        return live
    }

    private func tabContent(_ arguments: Arguments, kind: TabContentKind) async throws -> String {
        let id = try arguments.tabID("id")
        _ = try await verified(id)
        let content = try await store.tabContent(
            id, kind: kind, characterLimit: Configuration.pageCharacterLimit)
        return format.tabContent(content)
    }

    private func closeTab(_ arguments: Arguments) async throws -> String {
        let id = try arguments.tabID("id")
        // Verified before the confirmation is checked, so a stale id is reported as stale
        // rather than as a missing confirmation — the caller would otherwise re-send with
        // confirm=true and close the wrong tab.
        _ = try await verified(id)
        guard arguments.bool("confirm") else {
            throw ToolError.confirmationRequired(action: "Closing a tab")
        }
        return format.closed(try await store.closeTab(id))
    }

    private func runJavaScript(_ arguments: Arguments) async throws -> String {
        let id = try arguments.tabID("id")
        let script = try arguments.requiredString("script")
        // Verified before the confirmation is checked, for the same reason close_tab
        // does: a stale id is reported as stale rather than as a missing confirmation,
        // so the caller does not re-send with confirm=true against the wrong tab.
        _ = try await verified(id)
        guard arguments.bool("confirm") else {
            throw ToolError.confirmationRequired(action: "Running a script")
        }
        return format.javascriptResult(try await store.runJavaScript(id, script: script))
    }

    private func addToReadingList(_ arguments: Arguments) async throws -> String {
        let url = try arguments.webURL("url")
        let title = arguments.optionalString("title")
        try await store.addReadingListItem(
            url: url, title: title, previewText: arguments.optionalString("preview_text"))
        return format.readingListAdded(url: url, title: title)
    }

    // MARK: Library

    private func bookmarks(_ arguments: Arguments) async throws -> String {
        let all = try await store.bookmarks()
        let folder = arguments.optionalString("folder")
        let limit = try arguments.int(
            "limit", default: Configuration.searchLimit, in: Configuration.searchLimitRange)

        // Filtered above the seam because a bookmark file holds hundreds of rows, not
        // millions: the store hands over what it read and the policy stays testable.
        var matches = all
        if let folder {
            matches = matches.filter {
                $0.folderPath.lowercased().hasPrefix(folder.lowercased())
            }
        }
        let total = matches.count
        return format.bookmarkList(Array(matches.prefix(limit)), folder: folder, total: total)
    }

    private func history(_ arguments: Arguments) async throws -> String {
        let from = try arguments.optionalDate("from")
        let to = try arguments.optionalDate("to")

        // A bare day as an upper bound means the whole of that day. Stopping at its
        // midnight would silently drop everything the person did today, which is the
        // range they most often mean.
        var upperBound = to?.date
        if let to, to.isDateOnly {
            upperBound = calendar.date(byAdding: .day, value: 1, to: to.date)
        }
        if let lower = from?.date, let upper = upperBound, upper < lower {
            throw ToolError.badArgument(
                name: "to", reason: "it is before 'from'; a range cannot end before it starts")
        }

        let limit = try arguments.int(
            "limit", default: Configuration.searchLimit, in: Configuration.searchLimitRange)
        let query = arguments.optionalString("query")
        let page = try await store.history(
            query: query, from: from?.date, to: upperBound, limit: limit)
        return format.historyResults(page, query: query, from: from?.date, to: to?.date)
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
