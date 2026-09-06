import Foundation

/// Whether Safari can be driven at all, and if not, why.
///
/// There is no `authorizationStatus` for Apple events the way there is for Contacts or
/// EventKit, so this collapses several distinct causes — Safari missing, Safari not
/// running, consent refused — into one value the tools can act on.
public enum SafariAvailability: Sendable, Equatable {
    case ready
    case notInstalled
    /// Safari is installed but not launched. This server does not launch it: starting a
    /// browser on someone's behalf is a side effect they did not ask for, and an
    /// unlaunched Safari has no tabs to report anyway.
    case notRunning
    case automationDenied
    /// macOS has not asked yet. The first real Apple event raises the dialog.
    case consentNotGranted

    /// Whether a tool call must be refused outright.
    ///
    /// `.consentNotGranted` deliberately does **not** block, which is why "may a call
    /// proceed" is a different question from "is Safari ready". macOS only shows the
    /// Automation dialog when a real Apple event is sent, so refusing here would mean the
    /// dialog never appears and the permission could never be granted at all. If consent
    /// is then refused, the event fails and the error path reports it.
    public var blocksCalls: Bool {
        switch self {
        case .ready, .consentNotGranted: return false
        case .notInstalled, .notRunning, .automationDenied: return true
        }
    }
}

/// Whether a file under `~/Library/Safari` can be read.
///
/// Bookmarks and history are not Apple events at all: they are files, behind Full Disk
/// Access. That grant has no usage-description key and cannot be requested from code —
/// it is given by hand in System Settings — so the only honest thing a program can do is
/// tell the three cases apart and say which one it is in.
public enum LibraryAccess: Sendable, Equatable {
    case readable
    /// The file is there and `stat` succeeds, but opening it returns EPERM. That is what
    /// a missing Full Disk Access grant looks like from inside the process.
    case blocked
    /// No such file. Safari has never written one, or the format moved.
    case missing
}

public struct LibraryStatus: Sendable, Equatable {
    public let bookmarks: LibraryAccess
    public let history: LibraryAccess

    public init(bookmarks: LibraryAccess, history: LibraryAccess) {
        self.bookmarks = bookmarks
        self.history = history
    }
}

/// The seam between the tool layer and Safari.
///
/// Nothing above this protocol sends an Apple event or opens a file, which is what lets
/// the tests drive every branch against an in-memory double — with Safari closed, no
/// permission granted and not one page of the owner's read.
public protocol SafariStore: Sendable {
    func availability() -> SafariAvailability

    /// Read separately from `availability()` because the two grants are unrelated: Safari
    /// automation can be permitted while the history database stays unreadable, and the
    /// status tool has to be able to say so.
    func libraryStatus() -> LibraryStatus

    func windows() async throws -> [WindowInfo]

    /// The tab's title and URL as they are **now**, reading no page content.
    ///
    /// This is what makes the fingerprint check cheap enough to run before every call
    /// that reads or closes a tab: two properties instead of a whole rendered page.
    func tabSummary(_ id: TabID) async throws -> TabSummary

    /// `characterLimit` is passed per call rather than held by the store so that the
    /// value the tools enforce and the value `safari_status` reports cannot be two
    /// different numbers.
    func tabContent(_ id: TabID, kind: TabContentKind, characterLimit: Int) async throws
        -> TabContent

    func openURL(_ url: String) async throws -> OpenedTab

    /// Returns the tab as it was immediately before closing. Irreversible: a closed tab
    /// takes its scroll position, its form state and its back history with it.
    func closeTab(_ id: TabID) async throws -> TabSummary

    /// Write-only by nature — Safari's dictionary offers no way to read the Reading List
    /// back, so nothing here can confirm what is already in it.
    func addReadingListItem(url: String, title: String?, previewText: String?) async throws

    /// Runs `script` inside the tab named by `id` and returns what it evaluated to,
    /// rendered as text.
    ///
    /// No restriction on which tab: this runs exactly what the page's own script could
    /// run, in whatever session that tab holds. The caller — `SafariTools` — is what
    /// verifies the id still points at the page it was minted for before this is reached.
    func runJavaScript(_ id: TabID, script: String) async throws -> JavaScriptResult

    /// Every bookmark, flattened, with the folder path each one sits in.
    ///
    /// Returned whole rather than filtered, because a bookmark file holds hundreds of
    /// rows rather than millions and filtering above the seam is filtering the tests can
    /// reach. Throws when Full Disk Access is missing; never returns an empty list to
    /// mean "blocked".
    func bookmarks() async throws -> [Bookmark]

    /// Filtered in SQL rather than above the seam: a history database holds hundreds of
    /// thousands of rows, which is the one case where the filter has to go down with the
    /// query. Throws when Full Disk Access is missing.
    func history(query: String?, from: Date?, to: Date?, limit: Int) async throws -> HistoryPage
}
