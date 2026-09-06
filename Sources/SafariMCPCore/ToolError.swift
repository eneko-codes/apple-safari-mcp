import Foundation

public enum ToolError: Error, Equatable {
    case notAvailable(SafariAvailability)
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case badDate(argument: String, value: String)
    case badIdentifier(String)
    case tabGone(id: String)
    case tabChanged(id: String, url: String)
    case unsupportedScheme(url: String, scheme: String)
    case confirmationRequired(action: String)
    case pageSourceDisabled
    case javascriptDisabled
    case fullDiskAccessRequired(what: String, path: String)
    case libraryFileMissing(what: String, path: String)
    case javascriptRefused(String)
    case storeFailure(String)

    public var message: String {
        switch self {
        case .notAvailable(let state):
            return Self.availabilityMessage(state)

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

        case .badDate(let argument, let value):
            return """
                Argument '\(argument)' is not a date this server accepts: '\(value)'

                Use 2026-08-12, 2026-08-12T09:00, or 2026-08-12T09:00:00+02:00.
                """

        case .badIdentifier(let raw):
            return """
                '\(raw)' is not a tab id from this server.

                Tab ids are opaque tokens produced by tabs_list. They cannot be typed by
                hand, and a window number or a tab position is not one.
                """

        case .tabGone(let id):
            return """
                No open tab answers to id '\(id)'.

                The window was closed, or the tab was — a tab id names a position in a
                window, and there is nothing at that position any more. Run tabs_list
                again to see what is actually open.
                """

        // The fingerprint in the id is what catches this. Positions renumber the moment a
        // tab is closed or dragged, so acting on a stale id would read, or close, the
        // neighbour of the tab that was meant.
        case .tabChanged(let id, let url):
            return """
                The tab id '\(id)' no longer points at the page it was made for.

                What is at that position now:
                  \(url)

                Either the tabs were reordered, or that tab navigated somewhere else.
                Nothing was read and nothing was closed. Run tabs_list again and use the
                id it returns now.
                """

        case .unsupportedScheme(let url, let scheme):
            return """
                This server only opens http and https URLs, and '\(url)' is '\(scheme)'.

                A 'javascript:' URL is the do-JavaScript command wearing a different hat:
                it executes inside whatever session is signed in. 'file:' and 'data:'
                reach the disk and the page's own origin. None of them are opened here.
                """

        case .confirmationRequired(let action):
            return """
                \(action) requires confirm=true.

                A closed tab cannot be reopened from here: it takes its scroll position,
                its form state and its back history with it, and "Reopen Last Closed Tab"
                is a menu gesture only the person at the keyboard can make. Show them
                which tab you mean, then call again with confirm=true.
                """

        case .pageSourceDisabled:
            return """
                Reading raw HTML is switched off for this extension.

                tab_get_text returns the rendered text of the same page and is what almost
                every question actually needs. Raw source is opt-in because it carries
                inline scripts, tracking markup and embedded tokens that the rendered text
                does not.

                Turn it on in Claude Desktop → Settings → Extensions → Apple Safari →
                "Allow reading raw page source".
                """

        // Full Disk Access has no usage-description key and cannot be requested from
        // code. Detecting the refusal and saying exactly where to fix it is the whole of
        // what a program can do here.
        case .fullDiskAccessRequired(let what, let path):
            return """
                Cannot read Safari's \(what): macOS is blocking it.

                  \(path)

                Everything under ~/Library/Safari needs Full Disk Access. Unlike the other
                permissions this server uses, there is no key it can declare and no dialog
                it can raise — the grant is given by hand:

                  System Settings → Privacy & Security → Full Disk Access → + → add
                  "apple-safari-mcp"
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad →
                  Acceso total al disco)

                The binary to add is the one inside the installed extension:
                  ~/Library/Application Support/Claude/Claude Extensions/
                    <extension folder>/server/apple-safari-mcp

                Then restart Claude Desktop: the permission is resolved when the process
                starts. Tabs, Reading List and open/close keep working without it — they
                go through Safari, not through the disk.
                """

        case .javascriptDisabled:
            return """
                Running JavaScript is switched off for this extension.

                Turn it on in Claude Desktop → Settings → Extensions → Apple Safari → \
                "Allow running JavaScript". Note that this is not scoped to one site: \
                once on, run_javascript works in any tab it is given.
                """

        case .javascriptRefused(let detail):
            return """
                Safari refused to run the script: \(detail)

                The one cause seen in practice is Safari's own developer setting for this
                exact command being off, which is off by default on every Mac:

                  Safari → Settings → Advanced → turn on "Show features for web
                  developers" → Develop menu → Allow JavaScript from Apple Events

                If that is already on, the script itself may have thrown — Safari reports
                a script's own exception the same way it reports this setting being off.

                Seen in practice: Safari refusing every script, including a trivial one,
                right after it was relaunched, with the setting confirmed on and no
                further detail available. If this keeps happening only just after Safari
                starts, try again once it has settled, or quit and relaunch Safari.
                """

        case .libraryFileMissing(let what, let path):
            return """
                Safari's \(what) file is not where this server expects it.

                  \(path)

                The file is readable-in-principle — this is not a permissions problem.
                Either Safari has never written one on this Mac, or the format has moved.
                """

        case .storeFailure(let detail):
            return "Safari returned an error: \(detail)"
        }
    }

    static func availabilityMessage(_ state: SafariAvailability) -> String {
        switch state {
        case .ready:
            return "Safari is running and automation is permitted."

        case .notInstalled:
            return """
                Safari is not installed on this Mac, so there is nothing to control.
                """

        case .notRunning:
            return """
                Safari is not running.

                This server will not launch it: opening a browser is a visible side effect
                nobody asked for, and a browser that has just started has no tabs to read.
                Open Safari and try again.
                """

        case .automationDenied:
            return """
                Permission to control Safari is denied.

                Grant it in:
                  System Settings → Privacy & Security → Automation → "apple-safari-mcp"
                  → enable "Safari"
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad →
                  Automatización)

                Then restart Claude Desktop: the permission is resolved when the process
                starts.
                """

        case .consentNotGranted:
            return """
                macOS has not asked yet whether this server may control Safari.

                The dialog appears the first time a real Apple event is sent, so call any
                tab tool and answer it. If no dialog appears, check that the binary still
                carries its embedded Info.plist:
                  otool -P .build/release/apple-safari-mcp | grep NSAppleEvents
                """
        }
    }
}
