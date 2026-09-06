import Foundation

/// Settings the person installing the extension can change.
///
/// This arrives as command-line arguments because that is how a Claude extension passes
/// `user_config`: the manifest substitutes `${user_config.key}` into `mcp_config.args`.
/// Parsing is hand-rolled rather than pulling in an argument-parsing package — the whole
/// surface is one setting, and every dependency in this repo has to earn its place.
public struct Configuration: Sendable, Equatable {
    /// Whether `tab_get_source` may return raw HTML. Off unless deliberately switched on.
    ///
    /// Not a preference — a boundary. Rendered text is what a question about a page
    /// actually needs; raw source additionally carries inline scripts, tracking markup
    /// and any token the page embedded in itself. Defaulting that to "on" would hand it
    /// over without anyone having decided to.
    public var allowsPageSource: Bool = false

    /// Whether `run_javascript` may run at all. Off unless deliberately switched on.
    ///
    /// Not scoped by site — there is no allowlist here, by design: once this is on,
    /// `run_javascript` runs in whatever tab it is given, the same as Safari's own `do
    /// JavaScript` does for a person driving it by hand. The boundary this flag draws is
    /// coarser than `allowsPageSource`'s — on or off for the whole capability — because
    /// there is no narrower boundary a whitelist here would actually enforce: the tab is
    /// chosen per call, not fixed at configuration time.
    public var allowsJavaScript: Bool = false

    public init() {}

    /// Ceiling on how much of one page crosses the boundary, in characters. A long
    /// article runs to tens of thousands; a web application can run to millions.
    ///
    /// Fixed rather than a `user_config` setting: the manifest's own default was the only
    /// value this ever ran with in practice, so the setting bought configurability nobody
    /// used. Raising it is a code change, not a Claude Desktop one.
    public static let pageCharacterLimit = 40_000

    /// Default page size for `history_search` and `bookmarks_list`. The tool's own
    /// `limit` still wins.
    ///
    /// Fixed for the same reason as `pageCharacterLimit` — this is the manifest's former
    /// default, now the only value.
    public static let searchLimit = 50

    public static let searchLimitRange = 1...500

    /// Paging ceiling. Declared here so the advertised schema and the enforced clamp
    /// cannot drift: both read this one value.
    public static let offsetRange = 0...10_000

    /// True when an argument is an unsubstituted manifest placeholder.
    ///
    /// Claude Desktop leaves `${user_config.key}` untouched when the person left that
    /// setting empty, so the literal text arrives as an argument. Taking it at face value
    /// is worse than ignoring it: `--allow-page-source ${user_config.allow_page_source}`
    /// would otherwise parse as neither yes nor no, which is harmless only because that
    /// flag falls back to its safer default either way. A future flag parsed as a number
    /// would have no such safe fallback and could stop the server from starting.
    static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("${") && trimmed.hasSuffix("}")
    }

    /// Unknown flags are ignored rather than fatal. A server that will not launch is much
    /// harder to diagnose than one running on a default.
    public static func parse(_ arguments: [String]) -> Configuration {
        var configuration = Configuration()
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil

            switch flag {
            case "--allow-page-source":
                // Only an explicit yes turns it on. A placeholder, a typo or an absent
                // value all leave the safer default in place.
                if let value, !isPlaceholder(value) {
                    configuration.allowsPageSource = ["true", "yes", "1"].contains(
                        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                }
                index += 2

            case "--allow-javascript":
                if let value, !isPlaceholder(value) {
                    configuration.allowsJavaScript = ["true", "yes", "1"].contains(
                        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                }
                index += 2

            default:
                index += 1
            }
        }
        return configuration
    }
}
