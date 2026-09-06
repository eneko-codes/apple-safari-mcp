#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const SafariBridgeErrorDomain;

/// Typed because Swift imports an `NSError **` method as `throws`, which would otherwise
/// flatten "that window has no tab at that position" — an ordinary outcome, since tab
/// positions shift whenever a tab is closed or dragged — into the same channel as a real
/// failure.
typedef NS_ERROR_ENUM(SafariBridgeErrorDomain, SafariBridgeError){
    SafariBridgeErrorSafariNotRunning = 1,
    SafariBridgeErrorNotReachable,
    SafariBridgeErrorWindowNotFound,
    SafariBridgeErrorTabNotFound,
    SafariBridgeErrorOpenRefused,
    /// Safari refused `do JavaScript` outright — not a script error, a policy one. The
    /// only known cause is Safari's own "Allow JavaScript from Apple Events" developer
    /// setting being off, which is off by default on every Mac.
    SafariBridgeErrorJavaScriptRefused,
};

/// Everything this project sends to Safari, in Objective-C.
///
/// Objective-C rather than Swift on purpose, and not for taste. Apple documents exactly
/// one way to create a scriptable object — ask the application for the class with
/// `classForScriptingClass:`, `alloc`/`initWithProperties:` it, then insert it in the
/// container's element array — and that pattern cannot be expressed from Swift. The class
/// that comes back is an `SBPseudoClass`, which does not inherit from `SBObject` and turns
/// every class-level message into an `__NSMessageBuilder`, so a Swift metatype cast
/// against it aborts the process. Underneath is a Swift limitation of long standing: the
/// metadata symbols for Scripting Bridge classes do not exist at link time because the
/// classes are made at runtime (swiftlang/swift#43407, open since 2016).
///
/// In Objective-C none of that arises. A cast to a protocol is a compile-time annotation,
/// the documented creation pattern compiles as written, and no `unsafeBitCast` is needed
/// anywhere. The alternative — driving Safari through `NSAppleScript` — is the one thing
/// Apple's own guide tells you not to do: "You should not use NSAppleScript to execute a
/// script merely to result in sending an Apple event."
///
/// Everything crosses back to Swift as Foundation types, so no Scripting Bridge object
/// ever escapes this file. Policy — which tab to address, whether an id still points at
/// the page it was minted for, how much text to keep, how to format — stays in Swift,
/// where the tests can reach it.
///
/// One member of Safari's dictionary is deliberately absent and must stay absent: `email
/// contents`, which sends mail on the owner's behalf. `do JavaScript` is declared and
/// reachable through `runJavaScript:inTabAtIndex:inWindow:error:` — it runs arbitrary code
/// inside whatever tab it targets, with no restriction on which one, so the caller in
/// Swift is trusted to have a reason for the tab it names.
@interface SafariBridge : NSObject

/// Whether Safari is running. This server never launches it.
@property (class, readonly) BOOL isSafariRunning;

/// Every window, as `{id, name, currentTabIndex, tabs: [{index, name, url}]}`.
///
/// `index` is the tab's position from the left, counted from 1, and is the only handle
/// Safari's dictionary offers for addressing a tab. It is not an identifier: closing or
/// dragging a tab renumbers the ones after it. Whoever holds one has to check that it
/// still points at the same page before acting on it.
+ (nullable NSArray<NSDictionary<NSString *, id> *> *)windowsWithError:(NSError **)error;

/// One tab as `{name, url}`, plus `text` and `source` when asked for.
///
/// Both flags NO reads only the two cheap properties, which is what makes it usable as a
/// "is this still the page I mean?" check before doing something irreversible. `text` is
/// the page as rendered — it is whatever the tab is displaying, logged-in and paywalled
/// content included — and `source` is the raw HTML.
+ (nullable NSDictionary<NSString *, id> *)tabAtIndex:(NSInteger)index
                                             inWindow:(NSInteger)windowIdentifier
                                          includeText:(BOOL)includeText
                                        includeSource:(BOOL)includeSource
                                                error:(NSError **)error;

/// Opens a URL in a new tab of the frontmost window, or in a new window when Safari has
/// none open. Returns `{windowId, index, name, url}` describing the tab it created.
///
/// The caller is responsible for rejecting schemes: this method sends whatever it is
/// given, and `javascript:` in a URL bar is `do JavaScript` by another name.
+ (nullable NSDictionary<NSString *, id> *)openURL:(NSString *)url error:(NSError **)error;

/// Closes one tab and returns `{name, url}` as it was immediately before closing, so the
/// caller can say precisely what disappeared.
///
/// Irreversible. A closed tab takes its scroll position, its form state and its back
/// history with it, and Safari's "Reopen Last Closed Tab" is a user gesture this server
/// cannot perform.
+ (nullable NSDictionary<NSString *, id> *)closeTabAtIndex:(NSInteger)index
                                                  inWindow:(NSInteger)windowIdentifier
                                                     error:(NSError **)error;

/// Adds a URL to the Reading List. Safari's dictionary offers no way to read the list
/// back, so this is write-only by nature.
+ (BOOL)addReadingListItem:(NSString *)url
                     title:(nullable NSString *)title
               previewText:(nullable NSString *)previewText
                     error:(NSError **)error;

/// Runs `script` inside the tab at `index` in `windowIdentifier` and returns whatever the
/// script evaluates to, coerced to a Foundation type by Safari itself — a string, a
/// number, a boolean, an array or dictionary of those, or `NSNull` for `undefined`.
///
/// This is Safari's own `do JavaScript "..." in tab N of window M` — full page access,
/// exactly as if the page's own script had run: it can read what the page can read and do
/// what a click on the page could do. Nothing here restricts which tab: the caller decides,
/// the same way `tabAtIndex:inWindow:` already trusts its caller for every other command.
+ (nullable id)runJavaScript:(NSString *)script
              inTabAtIndex:(NSInteger)index
                  inWindow:(NSInteger)windowIdentifier
                     error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
