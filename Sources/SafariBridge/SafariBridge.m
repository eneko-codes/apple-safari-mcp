#import "SafariBridge.h"

#import <AppKit/AppKit.h>
#import <ScriptingBridge/ScriptingBridge.h>

// Hand-declared bindings for Safari, covering only the members this server sends.
//
// `sdef /Applications/Safari.app | sdp -fh` generates a full header for the whole
// dictionary; declaring the handful of members actually used is smaller and auditable.
// Every selector here was checked against Safari's scripting dictionary — confirm before
// adding one:
//
//     sdef /Applications/Safari.app | grep 'name="text"'
//
// Scripting Bridge camel-cases dictionary names: `current tab` becomes `currentTab`, and
// the command `add reading list item ... and preview text ... with title ...` becomes
// `addReadingListItem:andPreviewText:withTitle:`.
//
// Two members are deliberately absent. `do JavaScript` evaluates arbitrary code inside a
// logged-in browsing session; `email contents` sends mail. Neither is declared, so
// neither can be sent from this process. For the same reason nothing is declared "in case
// it is useful later": every member here is one this server sends.

/// `close` takes a save option even for a tab, which never has one. Only the four-char
/// code for "no" is declared, because it is the only one this server passes.
typedef NS_ENUM(unsigned int, SafariSaveOptions) {
    SafariSaveOptionsNo = 'no  ',
};

@protocol SafariTab <NSObject>
@property (copy, readonly) NSString *name;
@property (copy) NSString *URL;
/// The page as rendered — what the tab is displaying, not what the network would return.
@property (copy, readonly) NSString *text;
@property (copy, readonly) NSString *source;
- (void)closeSaving:(SafariSaveOptions)saving savingIn:(nullable NSURL *)savingIn;
@end

@protocol SafariWindow <NSObject>
@property (readonly) NSInteger id;
@property (copy, readonly) NSString *name;
@property (readonly) SBElementArray<id<SafariTab>> *tabs;
@property (copy) id<SafariTab> currentTab;
@end

@protocol SafariDocument <NSObject>
@property (copy) NSString *URL;
@end

@protocol SafariApplication <NSObject>
@property (readonly) SBElementArray<id<SafariWindow>> *windows;
@property (readonly) SBElementArray<id<SafariDocument>> *documents;
- (void)addReadingListItem:(NSString *)item
            andPreviewText:(nullable NSString *)previewText
                 withTitle:(nullable NSString *)title;
@end

NSString *const SafariBridgeErrorDomain = @"codes.eneko.apple-safari-mcp";
static NSString *const SafariBundleIdentifier = @"com.apple.Safari";

@implementation SafariBridge

#pragma mark - Plumbing

+ (BOOL)isSafariRunning {
    return [NSRunningApplication
               runningApplicationsWithBundleIdentifier:SafariBundleIdentifier].count > 0;
}

+ (NSError *)errorWithCode:(SafariBridgeError)code message:(NSString *)message {
    return [NSError errorWithDomain:SafariBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// The application object, or nil with `error` set. Casting to the protocol is a
/// compile-time annotation in Objective-C: no runtime check, no metadata symbol, and so
/// none of the trouble the same line causes in Swift.
+ (nullable SBApplication<SafariApplication> *)applicationWithError:(NSError **)error {
    if (!self.isSafariRunning) {
        if (error) {
            *error = [self errorWithCode:SafariBridgeErrorSafariNotRunning
                                 message:@"Safari is not running."];
        }
        return nil;
    }
    SBApplication *application =
        [SBApplication applicationWithBundleIdentifier:SafariBundleIdentifier];
    if (!application) {
        if (error) {
            *error = [self errorWithCode:SafariBridgeErrorNotReachable
                                 message:@"Safari could not be reached."];
        }
        return nil;
    }
    // No launch flag is set to keep Safari from starting, because none exists: the guard
    // is the isSafariRunning check above. Launching an app on the owner's behalf is a
    // side effect they did not ask for, and Scripting Bridge offers no way to forbid it.
    return (SBApplication<SafariApplication> *)application;
}

/// Windows are materialised before being walked. A Safari window that is not a browser
/// window — the downloads panel, a bookmarks editor — answers `tabs` with nothing, and is
/// skipped by the callers rather than being special-cased here.
+ (nullable id<SafariWindow>)windowWithIdentifier:(NSInteger)identifier
                                    inApplication:(SBApplication<SafariApplication> *)application {
    for (id<SafariWindow> window in application.windows) {
        if (window.id == identifier) return window;
    }
    return nil;
}

/// The tab at a 1-based position from the left, or nil.
///
/// The element array is materialised with `get` before indexing: `objectAtIndex:` on a
/// live `SBElementArray` raises on an out-of-range position instead of returning nil, and
/// an id minted before a tab was closed is exactly the out-of-range case this has to
/// survive.
+ (nullable id<SafariTab>)tabAtIndex:(NSInteger)index inWindow:(id<SafariWindow>)window {
    NSArray<id<SafariTab>> *tabs = [window.tabs get];
    if (index < 1 || index > (NSInteger)tabs.count) return nil;
    return tabs[index - 1];
}

+ (nullable id<SafariTab>)tabAtIndex:(NSInteger)index
                      inWindowNumber:(NSInteger)windowIdentifier
                       ofApplication:(SBApplication<SafariApplication> *)application
                               error:(NSError **)error {
    id<SafariWindow> window = [self windowWithIdentifier:windowIdentifier
                                           inApplication:application];
    if (!window) {
        if (error) {
            *error = [self errorWithCode:SafariBridgeErrorWindowNotFound
                                 message:[NSString stringWithFormat:
                                                       @"Safari has no window with id %ld.",
                                                       (long)windowIdentifier]];
        }
        return nil;
    }
    id<SafariTab> tab = [self tabAtIndex:index inWindow:window];
    if (!tab && error) {
        *error = [self errorWithCode:SafariBridgeErrorTabNotFound
                             message:[NSString stringWithFormat:
                                                   @"That window has no tab at position %ld.",
                                                   (long)index]];
    }
    return tab;
}

#pragma mark - Reads

+ (nullable NSArray<NSDictionary<NSString *, id> *> *)windowsWithError:(NSError **)error {
    SBApplication<SafariApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    NSMutableArray<NSDictionary<NSString *, id> *> *results = [NSMutableArray array];
    for (id<SafariWindow> window in application.windows) {
        NSArray<id<SafariTab>> *tabs = [window.tabs get];
        // A window with no tabs is not a browser window; it has nothing to report.
        if (tabs.count == 0) continue;

        NSString *currentName = window.currentTab.name;
        NSMutableArray<NSDictionary<NSString *, id> *> *entries = [NSMutableArray array];
        NSInteger position = 0;
        NSInteger currentPosition = 0;
        for (id<SafariTab> tab in tabs) {
            position += 1;
            NSString *name = tab.name ?: @"";
            // The current tab is matched by name rather than by object identity: the
            // proxies in a materialised array are not the same objects `currentTab`
            // returns, so a pointer comparison never matches. A duplicate title picks the
            // first, which is only ever a cosmetic marker in the listing.
            if (currentPosition == 0 && currentName.length > 0 &&
                [name isEqualToString:currentName]) {
                currentPosition = position;
            }
            [entries addObject:@{
                @"index": @(position),
                @"name": name,
                @"url": tab.URL ?: @"",
            }];
        }
        [results addObject:@{
            @"id": @(window.id),
            @"name": window.name ?: @"",
            @"currentTabIndex": @(currentPosition),
            @"tabs": entries,
        }];
    }
    return results;
}

+ (nullable NSDictionary<NSString *, id> *)tabAtIndex:(NSInteger)index
                                             inWindow:(NSInteger)windowIdentifier
                                          includeText:(BOOL)includeText
                                        includeSource:(BOOL)includeSource
                                                error:(NSError **)error {
    SBApplication<SafariApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    id<SafariTab> tab = [self tabAtIndex:index
                          inWindowNumber:windowIdentifier
                           ofApplication:application
                                   error:error];
    if (!tab) return nil;

    NSMutableDictionary<NSString *, id> *result = [NSMutableDictionary dictionary];
    result[@"name"] = tab.name ?: @"";
    result[@"url"] = tab.URL ?: @"";
    // Read last, and only when asked. Both properties pull the whole page across the
    // Apple event boundary, which is the expensive part of every call in this file.
    if (includeText) result[@"text"] = tab.text ?: @"";
    if (includeSource) result[@"source"] = tab.source ?: @"";
    return result;
}

#pragma mark - Writes

+ (nullable NSDictionary<NSString *, id> *)openURL:(NSString *)url error:(NSError **)error {
    SBApplication<SafariApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    id<SafariWindow> window = application.windows.firstObject;
    if (window && [window.tabs get].count > 0) {
        Class tabClass = [application classForScriptingClass:@"tab"];
        if (!tabClass) {
            if (error) {
                *error = [self errorWithCode:SafariBridgeErrorOpenRefused
                                     message:@"Safari did not offer its tab class."];
            }
            return nil;
        }
        id<SafariTab> tab = [[tabClass alloc] initWithProperties:@{@"URL": url}];
        if (!tab) {
            if (error) {
                *error = [self errorWithCode:SafariBridgeErrorOpenRefused
                                     message:@"Safari would not create the tab."];
            }
            return nil;
        }
        [window.tabs addObject:tab];

        // Scripting Bridge: an object "is not viable in the application until it has been
        // added to its container. Consequently, you cannot set or access its properties
        // until it's been added." The URL is passed at creation because that is the
        // dictionary's own idiom, and set again only if it did not take.
        NSArray<id<SafariTab>> *tabs = [window.tabs get];
        id<SafariTab> created = tabs.lastObject;
        if (created.URL.length == 0) created.URL = url;

        return @{
            @"windowId": @(window.id),
            @"index": @((NSInteger)tabs.count),
            @"name": created.name ?: @"",
            @"url": created.URL ?: url,
        };
    }

    // Safari is running with no browser window — after the last one is closed, or while
    // only a downloads panel is open. A new document is the dictionary's way to make one;
    // it is still not a launch, because Safari is already running.
    Class documentClass = [application classForScriptingClass:@"document"];
    if (!documentClass) {
        if (error) {
            *error = [self errorWithCode:SafariBridgeErrorOpenRefused
                                 message:@"Safari did not offer its document class."];
        }
        return nil;
    }
    id<SafariDocument> document = [[documentClass alloc] initWithProperties:@{@"URL": url}];
    if (!document) {
        if (error) {
            *error = [self errorWithCode:SafariBridgeErrorOpenRefused
                                 message:@"Safari would not open a new window."];
        }
        return nil;
    }
    [application.documents addObject:document];

    id<SafariWindow> opened = application.windows.firstObject;
    if (!opened) {
        if (error) {
            *error = [self errorWithCode:SafariBridgeErrorOpenRefused
                                 message:@"Safari opened nothing that can be addressed."];
        }
        return nil;
    }
    return @{
        @"windowId": @(opened.id),
        @"index": @(1),
        @"name": opened.currentTab.name ?: @"",
        @"url": opened.currentTab.URL ?: url,
    };
}

+ (nullable NSDictionary<NSString *, id> *)closeTabAtIndex:(NSInteger)index
                                                  inWindow:(NSInteger)windowIdentifier
                                                     error:(NSError **)error {
    SBApplication<SafariApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    id<SafariTab> tab = [self tabAtIndex:index
                          inWindowNumber:windowIdentifier
                           ofApplication:application
                                   error:error];
    if (!tab) return nil;

    // Read before closing: a closed tab is no longer there to be asked, and the receipt
    // should name what actually disappeared.
    NSDictionary<NSString *, id> *closed = @{
        @"name": tab.name ?: @"",
        @"url": tab.URL ?: @"",
    };
    [tab closeSaving:SafariSaveOptionsNo savingIn:nil];
    return closed;
}

+ (BOOL)addReadingListItem:(NSString *)url
                     title:(nullable NSString *)title
               previewText:(nullable NSString *)previewText
                     error:(NSError **)error {
    SBApplication<SafariApplication> *application = [self applicationWithError:error];
    if (!application) return NO;

    // Typed parameters, never text spliced into a script. There is no script source here
    // to splice into, which is the injection guarantee Scripting Bridge buys.
    [application addReadingListItem:url andPreviewText:previewText withTitle:title];
    return YES;
}

@end
