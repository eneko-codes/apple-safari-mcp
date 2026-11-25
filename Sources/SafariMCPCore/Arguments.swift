import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// A class, not a struct, so that reading a number can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call and
/// never leaves it. The tool hands `notices` to `Format`, which puts them before the data.
public final class Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    /// One sentence for each number that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    /// `nil` when the argument is absent or null, which mean the same: not given.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    /// Refuses an argument the tool's schema does not list, naming the ones it does. Without
    /// this, a call that still uses a renamed argument would run without it and return a
    /// different answer from the one asked for.
    public func refuseUnknown(allowed: [String]) throws {
        let unknown = values.keys.filter { !allowed.contains($0) }.sorted()
        guard let first = unknown.first else { return }
        throw ToolError.unknownArgument(
            name: first, others: unknown.count - 1, allowed: allowed.sorted())
    }

    // MARK: Scalars

    public func requiredString(_ name: String) throws -> String {
        guard given(name) != nil else { throw ToolError.missingArgument(name) }
        guard let text = try optionalString(name) else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return text
    }

    /// Blank text counts as not given, as it does for every text argument.
    public func optionalString(_ name: String) throws -> String? {
        guard let raw = given(name) else { return nil }
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func bool(_ name: String, default fallback: Bool = false) throws -> Bool {
        guard let raw = given(name) else { return fallback }
        guard let flag = raw.boolValue else {
            throw ToolError.badArgument(name: name, reason: "true or false was expected")
        }
        return flag
    }

    /// A quantity: a size, a count, a position in a listing. Outside its range it is moved
    /// to the nearest allowed value, and `notices` gains the sentence that says which value
    /// was used.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = given(name) else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "a whole number was expected")
        }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// The `limit` and `offset` of a listing, read the same way by every tool that pages.
    public func page(defaultLimit: Int, limits: ClosedRange<Int>) throws -> (limit: Int, offset: Int) {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: ToolCatalog.offsetRange)
        )
    }

    /// The `character_offset` and `max_characters` of one long text.
    public func window() throws -> (characterOffset: Int, maxCharacters: Int) {
        (
            try int("character_offset", default: 0, in: ToolCatalog.characterOffsetRange),
            try maxCharacters()
        )
    }

    public func maxCharacters() throws -> Int {
        try int(
            "max_characters", default: ToolCatalog.defaultMaxCharacters,
            in: ToolCatalog.maxCharactersRange)
    }

    // MARK: Dates

    /// How much of a date the caller wrote, which decides how much a range end covers: a bare
    /// day ends at the end of that day, a minute at the end of that minute.
    public enum Precision: Sendable, Equatable {
        case day, minute, second

        var component: Calendar.Component {
            switch self {
            case .day: return .day
            case .minute: return .minute
            case .second: return .second
            }
        }
    }

    /// `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM`, `YYYY-MM-DDTHH:MM:SS`, or full ISO 8601 with an
    /// offset. A date that does not exist (30 February, an hour a clock change skipped) is
    /// refused rather than moved to a neighbouring one.
    public func optionalDate(_ name: String) throws -> (date: Date, precision: Precision)? {
        guard let raw = try optionalString(name) else { return nil }
        let refusal = ToolError.badDate(argument: name, value: raw)

        let parts = raw.split(separator: "T", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw refusal }
        // An offset is a `+` or `-` after the time, or a trailing Z. Checking only for `+`
        // and `Z` sent `…T09:00:00-05:00` down the local-time path, which read the hour and
        // minute and dropped the offset without a word — a result five hours wrong.
        let hasOffset =
            parts.count == 2
            && (parts[1].contains("+") || parts[1].contains("-")
                || parts[1].uppercased().hasSuffix("Z"))

        let dayParts = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard dayParts.count == 3, let year = Int(dayParts[0]), let month = Int(dayParts[1]),
            let day = Int(dayParts[2]), Self.dayExists(year: year, month: month, day: day)
        else { throw refusal }

        if hasOffset {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: raw) else { throw refusal }
            return (date, .second)
        }

        var components = DateComponents(year: year, month: month, day: day)
        var precision = Precision.day
        if parts.count == 2 {
            let time = parts[1].split(separator: ":", omittingEmptySubsequences: false)
            guard time.count == 2 || time.count == 3, let hour = Int(time[0]),
                let minute = Int(time[1]), (0...23).contains(hour), (0...59).contains(minute)
            else { throw refusal }
            components.hour = hour
            components.minute = minute
            precision = .minute
            if time.count == 3 {
                guard let second = Int(time[2]), (0...59).contains(second) else { throw refusal }
                components.second = second
                precision = .second
            }
        }
        // `Calendar` is lenient: it turns an hour a clock change skipped into the next one.
        // Reading the components back catches that.
        guard let date = calendar.date(from: components) else { throw refusal }
        let readBack = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        guard readBack.year == year, readBack.month == month, readBack.day == day,
            precision == .day
                || (readBack.hour == components.hour && readBack.minute == components.minute
                    && readBack.second == (components.second ?? 0))
        else { throw refusal }
        return (date, precision)
    }

    private static func dayExists(year: Int, month: Int, day: Int) -> Bool {
        guard (1...12).contains(month), day >= 1 else { return false }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let first = gregorian.date(from: DateComponents(year: year, month: month, day: 1)),
            let days = gregorian.range(of: .day, in: .month, for: first)
        else { return false }
        return days.contains(day)
    }

    /// The first instant after a range end written at `precision`, so that an end is
    /// inclusive at the precision it was written: `2026-08-12` covers the whole day.
    public func exclusiveEnd(of date: Date, precision: Precision) -> Date {
        calendar.date(byAdding: precision.component, value: 1, to: date) ?? date
    }

    // MARK: URLs

    /// The only two schemes this server will open or save.
    ///
    /// The list is short on purpose. `javascript:` typed into a URL bar is the
    /// do-JavaScript command by another route, run in whatever page is loaded when the
    /// URL is opened rather than against a tab and a script the caller named — `open_url`
    /// stays a URL opener, not a second way to reach `run_javascript`. `file:` reaches
    /// the disk and `data:` carries its payload inline; neither is a page anybody asked
    /// to visit.
    public static let allowedSchemes: Set<String> = ["http", "https"]

    /// Returns the URL unchanged, or throws naming the scheme that was refused.
    ///
    /// A string with no scheme at all is treated as https, which is what a person means
    /// when they say "open example.com". Anything that does carry a scheme has to be one
    /// of the two allowed ones — guessing at the intent behind `javascript:` is exactly
    /// the guess not to make.
    public static func validatedWebURL(_ raw: String, argument: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: argument, reason: "it is empty")
        }
        // Matched by hand rather than with URLComponents: a bare "example.com/a:b" parses
        // as the scheme "example.com" under RFC 3986, and refusing that would be wrong.
        guard let colon = trimmed.firstIndex(of: ":") else { return "https://" + trimmed }
        let scheme = String(trimmed[trimmed.startIndex..<colon]).lowercased()
        let isSchemeShaped =
            !scheme.isEmpty && scheme.allSatisfy { $0.isLetter || $0.isNumber || "+-.".contains($0) }
            && scheme.first?.isLetter == true
        guard isSchemeShaped else { return "https://" + trimmed }
        guard allowedSchemes.contains(scheme) else {
            throw ToolError.unsupportedScheme(url: trimmed, scheme: scheme)
        }
        return trimmed
    }

    public func webURL(_ name: String) throws -> String {
        try Self.validatedWebURL(try requiredString(name), argument: name)
    }

    // MARK: Identifiers

    /// A tab id is an opaque token, never a number to move: one that does not decode is
    /// refused.
    public func tabID(_ name: String) throws -> TabID {
        let raw = try requiredString(name)
        guard let id = TabID.decode(raw) else { throw ToolError.badIdentifier(raw) }
        return id
    }
}
