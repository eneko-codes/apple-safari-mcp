import Foundation

/// Addresses one open tab.
///
/// Safari's dictionary gives a window a stable `id` but gives a tab nothing but its
/// position from the left, so a tab is addressed by window and position. A position is
/// not an identifier: closing or dragging a tab renumbers every tab after it, and an id
/// minted a minute ago can now point at a different page.
///
/// So the id carries a fingerprint of the URL it was minted for, and every call checks it
/// against the tab that is there now. A tab that has moved, or navigated somewhere else,
/// is refused rather than acted on — which is what stops `close_tab` from closing the
/// neighbour of the tab that was meant.
public struct TabID: Sendable, Equatable, Hashable {
    public let windowID: Int
    /// Position from the left, counted from 1, matching Safari's own `index`.
    public let index: Int
    public let urlFingerprint: String

    public init(windowID: Int, index: Int, urlFingerprint: String) {
        self.windowID = windowID
        self.index = index
        self.urlFingerprint = urlFingerprint
    }

    public init(windowID: Int, index: Int, url: String) {
        self.init(windowID: windowID, index: index, urlFingerprint: Self.fingerprint(of: url))
    }

    /// FNV-1a over the UTF-8 bytes, in hex.
    ///
    /// Hand-rolled because the requirement is *stable across processes*, which Swift's
    /// own `hashValue` explicitly is not — it is seeded per process, so an id minted by
    /// one run would never verify in the next. A cryptographic digest would also do, but
    /// nothing here is defending against a forged id: the fingerprint only has to notice
    /// that the page changed.
    public static func fingerprint(of url: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Unit separator: a control character that cannot occur in a URL, so the split is
    /// unambiguous before the base64 layer even matters.
    private static let separator = "\u{1F}"

    /// Encoded as base64url so the id reads as one opaque token and cannot be assembled
    /// by hand — a hand-made id would carry a fingerprint that matches nothing.
    public var encoded: String {
        let joined = [String(windowID), String(index), urlFingerprint]
            .joined(separator: Self.separator)
        return Data(joined.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ raw: String) -> TabID? {
        var padded = raw.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }

        guard let data = Data(base64Encoded: padded),
            let text = String(data: data, encoding: .utf8)
        else { return nil }

        let parts = text.components(separatedBy: separator)
        guard parts.count == 3, let windowID = Int(parts[0]), let index = Int(parts[1])
        else { return nil }
        return TabID(windowID: windowID, index: index, urlFingerprint: parts[2])
    }

    /// Whether this id still names the page it was minted for.
    public func matches(url: String) -> Bool {
        urlFingerprint == Self.fingerprint(of: url)
    }
}

public struct TabSummary: Sendable, Equatable {
    public let id: TabID
    public let title: String
    public let url: String
    /// The tab currently shown in its window. Every other tab in that window is loaded
    /// and readable all the same — Safari keeps their rendered text.
    public let isCurrent: Bool

    public init(id: TabID, title: String, url: String, isCurrent: Bool) {
        self.id = id
        self.title = title
        self.url = url
        self.isCurrent = isCurrent
    }
}

public struct WindowInfo: Sendable, Equatable {
    public let id: Int
    public let title: String
    public let tabs: [TabSummary]

    public init(id: Int, title: String, tabs: [TabSummary]) {
        self.id = id
        self.title = title
        self.tabs = tabs
    }
}

/// Which of a tab's two content properties to read.
public enum TabContentKind: String, Sendable, CaseIterable {
    /// `text` in the dictionary: the page as rendered.
    case text
    /// `source` in the dictionary: the raw HTML.
    case source
}

public struct TabContent: Sendable, Equatable {
    public let id: TabID
    public let title: String
    public let url: String
    public let kind: TabContentKind
    public let content: String
    /// True when `content` was cut to the configured limit, so the reader is never left
    /// to assume a truncated page is the whole thing.
    public let truncated: Bool
    /// Length before truncation, in characters.
    public let totalCharacters: Int

    public init(
        id: TabID, title: String, url: String, kind: TabContentKind, content: String,
        truncated: Bool, totalCharacters: Int
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.kind = kind
        self.content = content
        self.truncated = truncated
        self.totalCharacters = totalCharacters
    }
}

public struct Bookmark: Sendable, Equatable {
    /// Folders from the top down, joined with `/`. Empty for a bookmark sitting at the
    /// root of the favourites bar.
    public let folderPath: String
    public let title: String
    public let url: String

    public init(folderPath: String, title: String, url: String) {
        self.folderPath = folderPath
        self.title = title
        self.url = url
    }
}

public struct HistoryEntry: Sendable, Equatable {
    public let url: String
    public let title: String
    public let visitedAt: Date
    /// How many times Safari has recorded a visit to this URL in total, not within the
    /// searched range. It is the column's own meaning, reported as it is stored.
    public let visitCount: Int

    public init(url: String, title: String, visitedAt: Date, visitCount: Int) {
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
        self.visitCount = visitCount
    }
}

public struct HistoryPage: Sendable, Equatable {
    public let results: [HistoryEntry]
    /// True when the query stopped at the limit and there were more rows behind it.
    public let truncated: Bool

    public init(results: [HistoryEntry], truncated: Bool) {
        self.results = results
        self.truncated = truncated
    }
}

public struct OpenedTab: Sendable, Equatable {
    public let id: TabID
    public let title: String
    public let url: String

    public init(id: TabID, title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }
}

public struct JavaScriptResult: Sendable, Equatable {
    public let id: TabID
    public let script: String
    /// The script's return value, already rendered as text. JavaScript's own `undefined`
    /// and `null` are indistinguishable by the time this is built: Safari coerces both to
    /// `NSNull` crossing the Apple event boundary, and nothing on this side of it can
    /// recover which one a script actually returned.
    public let result: String

    public init(id: TabID, script: String, result: String) {
        self.id = id
        self.script = script
        self.result = result
    }
}
