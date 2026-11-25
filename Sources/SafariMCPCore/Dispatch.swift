import Foundation

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never sends an Apple event and never opens a file — everything goes through
/// `SafariStore`, which is what lets the tests drive every branch below against an
/// in-memory double with Safari closed and no permission granted.
public struct SafariTools: ToolHandler {
    private let store: any SafariStore
    private let calendar: Calendar
    private let configuration: Configuration
    private let format: Format
    private let deadline: Duration

    public init(
        store: any SafariStore,
        calendar: Calendar = .current,
        configuration: Configuration = Configuration(),
        deadline: Duration = ToolCatalog.callDeadline
    ) {
        self.store = store
        self.calendar = calendar
        self.configuration = configuration
        self.format = Format(calendar: calendar)
        self.deadline = deadline
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        // The work is abandoned at the deadline, not stopped: a call stuck inside Safari
        // holds its thread, and a late result is discarded.
        let outcome = await Deadline.run(within: deadline) {
            do {
                return Result<String, any Error>.success(try await run(parameters))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let text)?:
            return ToolOutput(text: text, isError: false)
        case .failure(let error)?:
            Diagnostics.toolFailed(parameters.name, error: error, since: started)
            if let error = error as? ToolError {
                return ToolOutput(text: error.message, isError: true)
            }
            return ToolOutput(
                text: ToolError.storeFailure(error.localizedDescription).message, isError: true)
        case nil:
            let timeout = ToolError.timedOut(
                seconds: Int(deadline.components.seconds),
                changes: ToolCatalog.writeNames.contains(parameters.name))
            Diagnostics.toolFailed(parameters.name, error: timeout, since: started)
            return ToolOutput(text: timeout.message, isError: true)
        }
    }

    private func run(_ parameters: ToolCall) async throws -> String {
        let arguments = Arguments(parameters.arguments, calendar: calendar)
        guard ToolCatalog.all(configuration).contains(where: { $0.name == parameters.name }) else {
            throw ToolError.unknownTool(parameters.name)
        }
        try arguments.refuseUnknown(
            allowed: ToolCatalog.argumentNames(of: parameters.name, configuration))

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
            return try await tabs(arguments)

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
            throw ToolError.unknownTool(parameters.name)
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

    private func tabs(_ arguments: Arguments) async throws -> String {
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultTabLimit, limits: ToolCatalog.tabLimitRange)
        let windows = try await store.windows()
        let rows = Format.tabRows(windows)
        return format.tabList(
            Array(rows.dropFirst(page.offset).prefix(page.limit)), offset: page.offset,
            total: rows.count, windows: windows.filter { !$0.tabs.isEmpty }.count,
            limit: page.limit, notices: arguments.notices)
    }

    private func tabContent(_ arguments: Arguments, kind: TabContentKind) async throws -> String {
        let id = try arguments.tabID("id")
        let window = try arguments.window()
        _ = try await verified(id)
        let content = try await store.tabContent(id, kind: kind)
        return format.tabContent(
            content, characterOffset: window.characterOffset,
            maxCharacters: window.maxCharacters, notices: arguments.notices)
    }

    private func closeTab(_ arguments: Arguments) async throws -> String {
        let id = try arguments.tabID("id")
        // Verified before the confirmation is checked, so a stale id is reported as stale
        // rather than as a missing confirmation — the caller would otherwise re-send with
        // confirm=true and close the wrong tab.
        _ = try await verified(id)
        guard try arguments.bool("confirm") else {
            throw ToolError.confirmationRequired(action: "Closing a tab")
        }
        return format.closed(try await store.closeTab(id))
    }

    private func runJavaScript(_ arguments: Arguments) async throws -> String {
        let id = try arguments.tabID("id")
        let script = try arguments.requiredString("script")
        let maxCharacters = try arguments.maxCharacters()
        // Verified before the confirmation is checked, for the same reason close_tab
        // does: a stale id is reported as stale rather than as a missing confirmation,
        // so the caller does not re-send with confirm=true against the wrong tab.
        _ = try await verified(id)
        guard try arguments.bool("confirm") else {
            throw ToolError.confirmationRequired(action: "Running a script")
        }
        return format.javascriptResult(
            try await store.runJavaScript(id, script: script), maxCharacters: maxCharacters,
            notices: arguments.notices)
    }

    private func addToReadingList(_ arguments: Arguments) async throws -> String {
        let url = try arguments.webURL("url")
        let title = try arguments.optionalString("title")
        try await store.addReadingListItem(
            url: url, title: title, previewText: try arguments.optionalString("preview_text"))
        return format.readingListAdded(url: url, title: title)
    }

    // MARK: Library

    private func bookmarks(_ arguments: Arguments) async throws -> String {
        let folder = try arguments.optionalString("folder")
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultBookmarkLimit, limits: ToolCatalog.bookmarkLimitRange)
        let all = try await store.bookmarks()

        // Filtered above the seam because a bookmark file holds hundreds of rows, not
        // millions: the store hands over what it read and the policy stays testable. The
        // order is the file's own, which does not change between two calls.
        var matches = all
        if let folder {
            matches = matches.filter {
                $0.folderPath.lowercased().hasPrefix(folder.lowercased())
            }
        }
        return format.bookmarkList(
            Array(matches.dropFirst(page.offset).prefix(page.limit)), offset: page.offset,
            total: matches.count, limit: page.limit, folder: folder, notices: arguments.notices)
    }

    private func history(_ arguments: Arguments) async throws -> String {
        let from = try arguments.optionalDate("from_date")
        let to = try arguments.optionalDate("to_date")

        // The end is inclusive at the precision the caller wrote: a bare day covers all of
        // that day, and stopping at its midnight would silently drop everything done today,
        // which is the range most often meant. The store takes an exclusive bound.
        let upperBound = to.map { arguments.exclusiveEnd(of: $0.date, precision: $0.precision) }
        if let lower = from?.date, let upper = upperBound, upper <= lower {
            throw ToolError.badArgument(
                name: "to_date",
                reason: "it is before 'from_date'; a range cannot end before it starts")
        }

        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultHistoryLimit, limits: ToolCatalog.historyLimitRange)
        let query = try arguments.optionalString("query")
        let results = try await store.history(
            query: query, from: from?.date, to: upperBound, limit: page.limit, offset: page.offset)
        return format.historyResults(
            results, offset: page.offset, limit: page.limit, query: query, fromDate: from?.date,
            toDate: to?.date, notices: arguments.notices)
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
