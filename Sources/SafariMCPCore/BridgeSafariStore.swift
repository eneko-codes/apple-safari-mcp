import AppKit
import Foundation
import SafariBridge

/// `SafariStore` backed by the real Safari, driven through Apple events, plus the two
/// files under `~/Library/Safari` that Apple events cannot reach.
///
/// Nothing here renders a page: every read is Safari handing back what it already has, so
/// `tab_get_text` returns the page as the person is seeing it and makes no network request
/// of its own. That is also why Safari has to be running.
///
/// The Apple events themselves live in the `SafariBridge` Objective-C target; see its
/// header for why they cannot live in Swift. Bookmarks and history live in
/// `SafariLibrary`. What stays here is the translation between the two and the tool
/// layer's own types — no policy, because policy is what the tests can reach through
/// `SafariStore`.
public struct BridgeSafariStore: SafariStore {
    public static let bundleIdentifier = "com.apple.Safari"

    public init() {}

    // MARK: Availability

    public func availability() -> SafariAvailability {
        guard
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
                != nil
        else { return .notInstalled }

        // "Not running" is checked before consent, and the order matters. Consent is
        // reported as pending until the first Apple event, and that event would launch
        // Safari — starting a browser on the owner's behalf is exactly the side effect
        // this server refuses to have. Answering `.notRunning` first keeps the refusal
        // ahead of the launch.
        guard SafariBridge.isSafariRunning else { return .notRunning }

        switch Self.automationPermission() {
        case OSStatus(errAEEventNotPermitted): return .automationDenied
        case OSStatus(errAEEventWouldRequireUserConsent): return .consentNotGranted
        case OSStatus(procNotFound): return .notRunning
        default: return .ready
        }
    }

    /// Asks TCC whether this process may drive Safari, **without sending a real event and
    /// without raising a dialog** (`askUserIfNeeded: false`). That is what lets
    /// `safari_status` be honest about permissions while reading no page at all.
    static func automationPermission() -> OSStatus {
        var target = AEAddressDesc()
        let identifier = Data(bundleIdentifier.utf8)
        let created = identifier.withUnsafeBytes { bytes in
            AECreateDesc(typeApplicationBundleID, bytes.baseAddress, bytes.count, &target)
        }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
    }

    public func libraryStatus() -> LibraryStatus { SafariLibrary.status() }

    /// The bridge reports failures as `NSError`; the tool layer speaks `ToolError`.
    private func storeFailure(_ error: Error) -> ToolError {
        let failure = error as NSError
        // A window or a tab that is no longer there is an ordinary outcome, not a fault:
        // ids go stale every time a tab is closed. Mapped so the caller is told to list
        // again rather than shown a raw bridge message.
        if failure.domain == SafariBridgeErrorDomain,
            failure.code == SafariBridgeError.windowNotFound.rawValue
                || failure.code == SafariBridgeError.tabNotFound.rawValue
        {
            return .tabGone(id: "(the tab it named)")
        }
        return .storeFailure(error.localizedDescription)
    }

    // MARK: Tabs

    public func windows() async throws -> [WindowInfo] {
        let raw: [[String: Any]]
        do { raw = try SafariBridge.windows() } catch { throw storeFailure(error) }

        return raw.compactMap { entry in
            guard let windowID = entry["id"] as? Int else { return nil }
            let currentIndex = entry["currentTabIndex"] as? Int ?? 0
            let tabs = (entry["tabs"] as? [[String: Any]] ?? []).compactMap {
                tab -> TabSummary? in
                guard let index = tab["index"] as? Int else { return nil }
                let url = tab["url"] as? String ?? ""
                return TabSummary(
                    id: TabID(windowID: windowID, index: index, url: url),
                    title: tab["name"] as? String ?? "",
                    url: url,
                    isCurrent: index == currentIndex)
            }
            return WindowInfo(
                id: windowID, title: entry["name"] as? String ?? "", tabs: tabs)
        }
    }

    public func tabSummary(_ id: TabID) async throws -> TabSummary {
        let raw = try read(id, includeText: false, includeSource: false)
        let url = raw["url"] as? String ?? ""
        return TabSummary(
            id: id, title: raw["name"] as? String ?? "", url: url,
            // Which tab is frontmost is a property of the window listing, not of one tab,
            // and nothing that reads a single tab needs to know it.
            isCurrent: false)
    }

    public func tabContent(_ id: TabID, kind: TabContentKind, characterLimit: Int) async throws
        -> TabContent
    {
        let raw = try read(id, includeText: kind == .text, includeSource: kind == .source)
        let whole = raw[kind.rawValue] as? String ?? ""
        // Counted in characters rather than bytes: the limit exists to bound what a model
        // has to read, and that is what a character is closer to.
        let truncated = whole.count > characterLimit
        return TabContent(
            id: id,
            title: raw["name"] as? String ?? "",
            url: raw["url"] as? String ?? "",
            kind: kind,
            content: truncated ? String(whole.prefix(characterLimit)) : whole,
            truncated: truncated,
            totalCharacters: whole.count)
    }

    private func read(_ id: TabID, includeText: Bool, includeSource: Bool) throws
        -> [String: Any]
    {
        do {
            return try SafariBridge.tab(
                at: id.index, inWindow: id.windowID, includeText: includeText,
                includeSource: includeSource)
        } catch {
            let failure = error as NSError
            guard failure.domain == SafariBridgeErrorDomain,
                failure.code == SafariBridgeError.windowNotFound.rawValue
                    || failure.code == SafariBridgeError.tabNotFound.rawValue
            else { throw storeFailure(error) }
            throw ToolError.tabGone(id: id.encoded)
        }
    }

    public func openURL(_ url: String) async throws -> OpenedTab {
        let raw: [String: Any]
        do { raw = try SafariBridge.openURL(url) } catch { throw storeFailure(error) }

        let windowID = raw["windowId"] as? Int ?? 0
        let index = raw["index"] as? Int ?? 1
        let openedURL = raw["url"] as? String ?? url
        return OpenedTab(
            id: TabID(windowID: windowID, index: index, url: openedURL),
            title: raw["name"] as? String ?? "",
            url: openedURL)
    }

    public func closeTab(_ id: TabID) async throws -> TabSummary {
        let raw: [String: Any]
        do {
            raw = try SafariBridge.closeTab(at: id.index, inWindow: id.windowID)
        } catch {
            let failure = error as NSError
            guard failure.domain == SafariBridgeErrorDomain,
                failure.code == SafariBridgeError.windowNotFound.rawValue
                    || failure.code == SafariBridgeError.tabNotFound.rawValue
            else { throw storeFailure(error) }
            throw ToolError.tabGone(id: id.encoded)
        }
        return TabSummary(
            id: id, title: raw["name"] as? String ?? "", url: raw["url"] as? String ?? "",
            isCurrent: false)
    }

    public func addReadingListItem(url: String, title: String?, previewText: String?)
        async throws
    {
        do {
            try SafariBridge.addReadingListItem(url, title: title, previewText: previewText)
        } catch {
            throw storeFailure(error)
        }
    }

    // MARK: Library

    public func bookmarks() async throws -> [Bookmark] { try SafariLibrary.bookmarks() }

    public func history(query: String?, from: Date?, to: Date?, limit: Int) async throws
        -> HistoryPage
    {
        try SafariLibrary.history(query: query, from: from, to: to, limit: limit)
    }
}
