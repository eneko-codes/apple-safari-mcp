import Foundation
import MCP

/// Typed access to a `tools/call` argument bag.
public struct Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    // MARK: Scalars

    public func requiredString(_ name: String) throws -> String {
        guard let raw = values[name]?.stringValue else { throw ToolError.missingArgument(name) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    public func optionalString(_ name: String) -> String? {
        guard let text = values[name]?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func bool(_ name: String, default fallback: Bool = false) -> Bool {
        values[name]?.boolValue ?? fallback
    }

    /// Clamps rather than rejects: a model asking for 5000 results means "as many as you
    /// will give me".
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = values[name] else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return Swift.min(Swift.max(number, range.lowerBound), range.upperBound)
    }

    // MARK: Dates

    /// `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM`, or full ISO 8601 with an offset.
    ///
    /// `isDateOnly` records what the caller actually wrote, because a bare day means
    /// different things at the two ends of a range: `to: 2026-08-12` has to include that
    /// whole day, not stop at midnight.
    public func optionalDate(_ name: String) throws -> (date: Date, isDateOnly: Bool)? {
        guard let raw = optionalString(name) else { return nil }

        let parts = raw.split(separator: "T", omittingEmptySubsequences: false)
        if parts.count == 1 || (parts.count == 2 && !raw.contains("Z") && !raw.contains("+")) {
            let dayParts = parts[0].split(separator: "-")
            guard dayParts.count == 3, let year = Int(dayParts[0]), let month = Int(dayParts[1]),
                let day = Int(dayParts[2]), (1...12).contains(month), (1...31).contains(day)
            else { throw ToolError.badDate(argument: name, value: raw) }

            var components = DateComponents(year: year, month: month, day: day)
            if parts.count == 2 {
                let time = parts[1].split(separator: ":")
                guard time.count >= 2, let hour = Int(time[0]), let minute = Int(time[1]),
                    (0...23).contains(hour), (0...59).contains(minute)
                else { throw ToolError.badDate(argument: name, value: raw) }
                components.hour = hour
                components.minute = minute
            }
            guard let date = calendar.date(from: components) else {
                throw ToolError.badDate(argument: name, value: raw)
            }
            return (date, parts.count == 1)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: raw) else {
            throw ToolError.badDate(argument: name, value: raw)
        }
        return (date, false)
    }

    // MARK: URLs

    /// The only two schemes this server will open or save.
    ///
    /// The list is short on purpose. `javascript:` typed into a URL bar is the
    /// do-JavaScript command by another route — it runs in the page's own origin, inside
    /// whatever session is signed in — and this server deliberately does not expose that
    /// command. `file:` reaches the disk and `data:` carries its payload inline; neither
    /// is a page anybody asked to visit.
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

    public func tabID(_ name: String) throws -> TabID {
        let raw = try requiredString(name)
        guard let id = TabID.decode(raw) else { throw ToolError.badIdentifier(raw) }
        return id
    }
}
