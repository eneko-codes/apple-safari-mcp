import Foundation
import SQLite3

/// The two Safari stores that are files rather than Apple events.
///
/// Below the `SafariStore` seam, like the Objective-C bridge, and for the same reason: no
/// test can reach it. Nothing here writes. The database is opened read-only and the plist
/// is read through `PropertyListSerialization`; Safari keeps both open while it runs and
/// this process must never be the reason one of them changes.
///
/// Everything under `~/Library/Safari` is behind **Full Disk Access**, which has no
/// usage-description key and cannot be requested from code. So the only honest thing this
/// type can do is tell the three cases apart — readable, blocked, absent — and report
/// which one it is in. Returning an empty list for "blocked" would be a lie the caller
/// could not detect.
enum SafariLibrary {

    static var bookmarksPath: String {
        NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"
    }

    static var historyPath: String {
        NSHomeDirectory() + "/Library/Safari/History.db"
    }

    /// `stat` succeeds under TCC but `open` does not, which is what makes the three cases
    /// distinguishable at all: a file that exists and cannot be read is a missing grant,
    /// and a file that is not there is something else entirely.
    static func access(_ path: String) -> LibraryAccess {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else { return .missing }
        return manager.isReadableFile(atPath: path) ? .readable : .blocked
    }

    static func status() -> LibraryStatus {
        LibraryStatus(bookmarks: access(bookmarksPath), history: access(historyPath))
    }

    // MARK: Bookmarks

    /// Every bookmark, flattened, with the folder path each one sits in.
    ///
    /// The plist is a tree of nodes tagged `WebBookmarkType`: `…TypeList` is a folder with
    /// `Children`, `…TypeLeaf` is a bookmark with `URLString` and a title inside
    /// `URIDictionary`, and `…TypeProxy` is a placeholder for something stored elsewhere
    /// (History) that holds no bookmarks at all.
    static func bookmarks() throws -> [Bookmark] {
        switch access(bookmarksPath) {
        case .blocked:
            throw ToolError.fullDiskAccessRequired(what: "bookmarks", path: bookmarksPath)
        case .missing:
            throw ToolError.libraryFileMissing(what: "bookmarks", path: bookmarksPath)
        case .readable:
            break
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: bookmarksPath))
        } catch {
            // A file that passed the readability check and then refused to open is the
            // grant being revoked mid-call, or a genuine I/O failure. Reported as the
            // permission problem it almost always is.
            throw ToolError.fullDiskAccessRequired(what: "bookmarks", path: bookmarksPath)
        }

        guard
            let root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else {
            throw ToolError.storeFailure(
                "Bookmarks.plist is not a property list this server understands.")
        }

        var collected: [Bookmark] = []
        collect(children: root["Children"] as? [[String: Any]] ?? [], path: [], into: &collected)
        return collected
    }

    private static func collect(
        children: [[String: Any]], path: [String], into results: inout [Bookmark]
    ) {
        for node in children {
            let type = node["WebBookmarkType"] as? String
            switch type {
            case "WebBookmarkTypeLeaf":
                guard let url = node["URLString"] as? String else { continue }
                let uri = node["URIDictionary"] as? [String: Any]
                let title = uri?["title"] as? String ?? url
                results.append(
                    Bookmark(folderPath: path.joined(separator: "/"), title: title, url: url))

            case "WebBookmarkTypeList":
                // The Reading List is a folder in this file, but it is a different thing:
                // it is a queue of unread pages, not a bookmark tree, and listing it here
                // would present saved-for-later items as bookmarks.
                if node["WebBookmarkIdentifier"] as? String == "com.apple.ReadingList" { continue }
                let title = node["Title"] as? String ?? "(untitled folder)"
                collect(
                    children: node["Children"] as? [[String: Any]] ?? [],
                    path: path + [title], into: &results)

            default:
                // WebBookmarkTypeProxy and anything a future Safari adds. Skipped rather
                // than guessed at.
                continue
            }
        }
    }

    // MARK: History

    /// Newest first, bounded by a date range and a limit.
    ///
    /// Filtered in SQL rather than above the seam because a history database holds
    /// hundreds of thousands of rows — the one place in this server where the filter has
    /// to travel with the query.
    static func history(query: String?, from: Date?, to: Date?, limit: Int) throws -> HistoryPage {
        switch access(historyPath) {
        case .blocked:
            throw ToolError.fullDiskAccessRequired(what: "history", path: historyPath)
        case .missing:
            throw ToolError.libraryFileMissing(what: "history", path: historyPath)
        case .readable:
            break
        }

        var database: OpaquePointer?
        // `mode=ro` rather than a plain path: the flag is what guarantees SQLite will not
        // write to a database Safari has open, and the URI form is the only way to pass
        // it. Safari runs the database in WAL mode, so a read here sees everything
        // checkpointed plus whatever the write-ahead log still holds.
        let uri = "file:" + percentEncoded(historyPath) + "?mode=ro"
        guard
            sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
            let database
        else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(database)
            throw ToolError.storeFailure("History.db could not be opened read-only: \(detail)")
        }
        defer { sqlite3_close(database) }

        var conditions: [String] = []
        if query != nil { conditions.append("(items.url LIKE ?1 ESCAPE '\\' OR visits.title LIKE ?1 ESCAPE '\\')") }
        if from != nil { conditions.append("visits.visit_time >= ?2") }
        if to != nil { conditions.append("visits.visit_time < ?3") }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        // Bound parameters throughout: the caller's text never becomes SQL. Numbered
        // rather than positional so an absent bound simply leaves its slot unbound.
        let sql = """
            SELECT items.url, visits.title, visits.visit_time, items.visit_count
            FROM history_visits AS visits
            JOIN history_items AS items ON items.id = visits.history_item
            \(whereClause)
            ORDER BY visits.visit_time DESC
            LIMIT ?4
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else {
            throw ToolError.storeFailure(
                "History query was rejected: \(String(cString: sqlite3_errmsg(database)))")
        }
        defer { sqlite3_finalize(statement) }

        if let query {
            // SQLITE_TRANSIENT: SQLite copies the bytes rather than holding this pointer,
            // which it would otherwise outlive.
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, "%" + likeEscaped(query) + "%", -1, transient)
        }
        if let from { sqlite3_bind_double(statement, 2, from.timeIntervalSinceReferenceDate) }
        if let to { sqlite3_bind_double(statement, 3, to.timeIntervalSinceReferenceDate) }
        // One more than asked for, so "there is more behind this" is a fact rather than a
        // guess made from a full page.
        sqlite3_bind_int(statement, 4, Int32(limit + 1))

        var results: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawURL = sqlite3_column_text(statement, 0) else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            results.append(
                HistoryEntry(
                    url: String(cString: rawURL),
                    title: title,
                    // Safari stores Mac absolute time: seconds since 2001-01-01 UTC.
                    visitedAt: Date(
                        timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2)),
                    visitCount: Int(sqlite3_column_int(statement, 3))))
        }

        let truncated = results.count > limit
        return HistoryPage(results: Array(results.prefix(limit)), truncated: truncated)
    }

    /// `%` and `_` are wildcards in LIKE, so a query containing one would silently match
    /// more than it says. Escaped with `\`, which the query declares via ESCAPE.
    private static func likeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// A file: URI needs its path percent-encoded, and a home directory can contain a
    /// space or a `#` that would otherwise truncate the path SQLite sees.
    private static func percentEncoded(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }
}
