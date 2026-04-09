#import "SMBAppDelegate.h"
#import "SMBConnection.h"
#import "SMBKeychainStore.h"
#import "SMBTaskRunner.h"

#include <arpa/inet.h>

static NSString *const kSMBBookmarkDefaultsKey = @"Bookmarks";
static NSString *const kSMBConnectionExchangeFormat = @"smb2fuse-connections";
static NSInteger const kSMBConnectionExchangeVersion = 1;
static NSInteger const kSMBEditorNameTag = 1001;
static NSInteger const kSMBEditorServerTag = 1002;
static NSInteger const kSMBEditorShareTag = 1003;
static NSInteger const kSMBEditorUserTag = 1004;
static NSInteger const kSMBEditorDomainTag = 1005;
static NSInteger const kSMBEditorBrowseSharesTag = 1006;
static NSInteger const kSMBEditorPasswordStateTag = 1007;
static NSInteger const kSMBEditorForgetPasswordTag = 1008;
static NSInteger const kSMBEditorErrorTag = 1099;

@interface SMBHintTextField : NSTextField

@property (copy) NSString *hintString;

@end

@implementation SMBHintTextField

- (void)drawRect:(NSRect)dirtyRect
{
    [super drawRect:dirtyRect];

    if ([[self stringValue] length] != 0 || [self currentEditor] != nil || [self.hintString length] == 0) {
        return;
    }

    NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:
                           [NSColor grayColor], NSForegroundColorAttributeName,
                           [self font] ?: [NSFont systemFontOfSize:12.0], NSFontAttributeName,
                           nil];
    NSRect bounds = [self bounds];
    NSPoint point = NSMakePoint(6.0, floor((bounds.size.height - 14.0) / 2.0));
    [self.hintString drawAtPoint:point withAttributes:attrs];
}

- (BOOL)becomeFirstResponder
{
    BOOL ok = [super becomeFirstResponder];
    [self setNeedsDisplay:YES];
    return ok;
}

- (BOOL)resignFirstResponder
{
    BOOL ok = [super resignFirstResponder];
    [self setNeedsDisplay:YES];
    return ok;
}

@end

@interface SMBBookmarkCellView : NSTableCellView

@property (strong) NSImageView *bookmarkIconView;
@property (strong) NSTextField *titleField;
@property (strong) NSTextField *subtitleField;
@property (strong) NSTextField *detailField;
@property (strong) NSTextField *mountedField;

@end

@implementation SMBBookmarkCellView

- (id)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (!self) {
        return nil;
    }

    self.bookmarkIconView = [[NSImageView alloc] initWithFrame:NSMakeRect(14.0, 12.0, 36.0, 36.0)];
    [self.bookmarkIconView setImageScaling:NSImageScaleProportionallyUpOrDown];
    [self addSubview:self.bookmarkIconView];

    self.titleField = [self labelWithFrame:NSMakeRect(62.0, 40.0, frameRect.size.width - 200.0, 18.0)
                                      bold:YES
                                      size:14.0];
    [self addSubview:self.titleField];

    self.subtitleField = [self labelWithFrame:NSMakeRect(62.0, 23.0, frameRect.size.width - 200.0, 16.0)
                                         bold:NO
                                         size:12.0];
    [self.subtitleField setTextColor:[NSColor darkGrayColor]];
    [self addSubview:self.subtitleField];

    self.detailField = [self labelWithFrame:NSMakeRect(62.0, 8.0, frameRect.size.width - 200.0, 14.0)
                                       bold:NO
                                       size:11.0];
    [self.detailField setTextColor:[NSColor grayColor]];
    [self addSubview:self.detailField];

    self.mountedField = [self labelWithFrame:NSMakeRect(frameRect.size.width - 146.0, 21.0, 132.0, 20.0)
                                        bold:NO
                                        size:11.0];
    [self.mountedField setAlignment:NSCenterTextAlignment];
    [self addSubview:self.mountedField];
    [self updateTextColors];

    return self;
}

- (void)layout
{
    [super layout];

    CGFloat width = [self bounds].size.width;
    [self.titleField setFrame:NSMakeRect(62.0, 40.0, width - 210.0, 18.0)];
    [self.subtitleField setFrame:NSMakeRect(62.0, 23.0, width - 210.0, 16.0)];
    [self.detailField setFrame:NSMakeRect(62.0, 8.0, width - 210.0, 14.0)];
    [self.mountedField setFrame:NSMakeRect(width - 146.0, 21.0, 132.0, 20.0)];
}

- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle
{
    [super setBackgroundStyle:backgroundStyle];
    [self updateTextColors];
}

- (NSTextField *)labelWithFrame:(NSRect)frame bold:(BOOL)bold size:(CGFloat)size
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    [label setBordered:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setDrawsBackground:NO];
    [label setFont:bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size]];
    [[label cell] setLineBreakMode:NSLineBreakByTruncatingTail];
    return label;
}

- (void)updateTextColors
{
    BOOL selected = ([self backgroundStyle] == NSBackgroundStyleDark);
    BOOL disconnected = [self.mountedField.stringValue isEqualToString:@"Not connected"];

    [self.titleField setTextColor:selected ? [NSColor whiteColor] : [NSColor blackColor]];
    [self.subtitleField setTextColor:selected ? [NSColor colorWithCalibratedWhite:0.92 alpha:1.0] : [NSColor darkGrayColor]];
    [self.detailField setTextColor:selected ? [NSColor colorWithCalibratedWhite:0.86 alpha:1.0] : [NSColor grayColor]];
    [self.mountedField setTextColor:selected
                                   ? (disconnected
                                      ? [NSColor colorWithCalibratedRed:1.0 green:0.84 blue:0.84 alpha:1.0]
                                      : [NSColor colorWithCalibratedRed:0.85 green:1.0 blue:0.85 alpha:1.0])
                                   : (disconnected
                                      ? [NSColor colorWithCalibratedRed:0.72 green:0.20 blue:0.20 alpha:1.0]
                                      : [NSColor colorWithCalibratedRed:0.20 green:0.62 blue:0.20 alpha:1.0])];
}

@end

@interface SMBBookmarkTableView : NSTableView

@property (assign) NSInteger contextualRow;

@end

@implementation SMBBookmarkTableView

- (id)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (!self) {
        return nil;
    }

    self.contextualRow = -1;
    return self;
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    NSInteger row = [self rowAtPoint:point];

    if (row < 0) {
        self.contextualRow = -1;
        [self deselectAll:nil];
        return nil;
    }

    self.contextualRow = row;
    if (![self isRowSelected:row]) {
        [self selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    }

    return [self menu];
}

@end

@interface SMBAppDelegate ()

@property (strong) NSWindow *window;
@property (strong) NSTableView *bookmarksTable;
@property (strong) NSView *emptyStateView;
@property (strong) NSTextField *statusField;
@property (strong) NSTextField *countField;
@property (strong) NSMenu *bookmarksMenu;
@property (strong) NSMenu *contextualMenu;

@property (strong) NSMutableArray *bookmarks;
@property (strong) SMBTaskRunner *taskRunner;
@property (strong) SMBKeychainStore *keychainStore;
@property (assign) BOOL taskRunning;
@property (assign) BOOL refreshInProgress;
@property (assign) BOOL refreshPending;
@property (assign) BOOL editorBrowseInProgress;

@end

@implementation SMBAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    (void)notification;
    self.bookmarks = [NSMutableArray array];
    self.taskRunner = [[SMBTaskRunner alloc] init];
    self.keychainStore = [[SMBKeychainStore alloc] init];

    [self loadBookmarks];
    [self installMainMenu];
    [self buildWindow];
    [self installWorkspaceObservers];
    [self.bookmarksTable reloadData];
    [self refreshCount];
    [self rebuildBookmarksMenu];
    [self updateEmptyState];
    [self requestMountedStateRefresh];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    (void)notification;
    [self requestMountedStateRefresh];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    (void)sender;
    return YES;
}

- (void)buildWindow
{
    NSRect frame = NSMakeRect(0.0, 0.0, 760.0, 560.0);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSTitledWindowMask |
                                                         NSClosableWindowMask |
                                                         NSMiniaturizableWindowMask |
                                                         NSResizableWindowMask)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    [self.window setTitle:@"SMB2 FUSE"];
    [self.window setMinSize:NSMakeSize(640.0, 420.0)];
    [self.window setDelegate:(id)self];

    NSView *contentView = [self.window contentView];
    NSRect bounds = [contentView bounds];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0.0, 34.0, bounds.size.width, bounds.size.height - 34.0)];
    [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [scrollView setBorderType:NSBezelBorder];
    [scrollView setHasVerticalScroller:YES];
    [contentView addSubview:scrollView];

    self.bookmarksTable = [[SMBBookmarkTableView alloc] initWithFrame:[[scrollView contentView] bounds]];
    [self.bookmarksTable setDelegate:self];
    [self.bookmarksTable setDataSource:self];
    [self.bookmarksTable setHeaderView:nil];
    [self.bookmarksTable setRowHeight:60.0];
    [self.bookmarksTable setIntercellSpacing:NSMakeSize(0.0, 0.0)];
    [self.bookmarksTable setUsesAlternatingRowBackgroundColors:YES];
    [self.bookmarksTable setDoubleAction:@selector(activateSelectedBookmark:)];
    [self.bookmarksTable addTableColumn:[self bookmarkColumn]];
    [self syncBookmarkColumnWidth];
    [self installContextualMenu];
    [scrollView setDocumentView:self.bookmarksTable];

    self.emptyStateView = [[NSView alloc] initWithFrame:[scrollView frame]];
    [self.emptyStateView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [self.emptyStateView setHidden:YES];
    [contentView addSubview:self.emptyStateView];

    NSTextField *emptyTitle = [self labelWithString:@"No Connections"
                                              frame:NSMakeRect(0.0, 0.0, 280.0, 28.0)
                                               bold:YES];
    [emptyTitle setAlignment:NSCenterTextAlignment];
    [emptyTitle setFont:[NSFont boldSystemFontOfSize:20.0]];
    [self.emptyStateView addSubview:emptyTitle];

    NSTextField *emptyMessage = [self labelWithString:@"Create a new connection to get started."
                                                frame:NSMakeRect(0.0, 0.0, 360.0, 20.0)
                                                 bold:NO];
    [emptyMessage setAlignment:NSCenterTextAlignment];
    [emptyMessage setTextColor:[NSColor darkGrayColor]];
    [emptyMessage setFont:[NSFont systemFontOfSize:13.0]];
    [self.emptyStateView addSubview:emptyMessage];

    NSTextField *emptyHint = [self labelWithString:@"File > New Connection..."
                                             frame:NSMakeRect(0.0, 0.0, 320.0, 18.0)
                                              bold:NO];
    [emptyHint setAlignment:NSCenterTextAlignment];
    [emptyHint setTextColor:[NSColor grayColor]];
    [emptyHint setFont:[NSFont systemFontOfSize:12.0]];
    [self.emptyStateView addSubview:emptyHint];

    [self positionEmptyStateSubviews];

    NSBox *statusBar = [[NSBox alloc] initWithFrame:NSMakeRect(0.0, 0.0, bounds.size.width, 34.0)];
    [statusBar setBoxType:NSBoxCustom];
    [statusBar setBorderType:NSNoBorder];
    [statusBar setBorderWidth:0.0];
    [statusBar setFillColor:[NSColor colorWithCalibratedWhite:0.95 alpha:1.0]];
    [statusBar setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    [contentView addSubview:statusBar];

    self.statusField = [self labelWithString:@"Ready."
                                       frame:NSMakeRect(14.0, 8.0, bounds.size.width - 160.0, 18.0)
                                        bold:NO];
    [self.statusField setAutoresizingMask:NSViewWidthSizable];
    [statusBar addSubview:self.statusField];

    self.countField = [self labelWithString:@"0 connections"
                                      frame:NSMakeRect(bounds.size.width - 140.0, 8.0, 126.0, 18.0)
                                       bold:NO];
    [self.countField setAlignment:NSRightTextAlignment];
    [self.countField setAutoresizingMask:NSViewMinXMargin];
    [statusBar addSubview:self.countField];
}

- (void)positionEmptyStateSubviews
{
    NSArray *subviews = [self.emptyStateView subviews];
    NSRect bounds = [self.emptyStateView bounds];
    CGFloat centerX = floor((bounds.size.width - 360.0) / 2.0);
    CGFloat centerY = floor((bounds.size.height - 90.0) / 2.0);

    if ([subviews count] < 3) {
        return;
    }

    [[subviews objectAtIndex:0] setFrame:NSMakeRect(centerX + 40.0, centerY + 38.0, 280.0, 28.0)];
    [[subviews objectAtIndex:1] setFrame:NSMakeRect(centerX, centerY + 12.0, 360.0, 20.0)];
    [[subviews objectAtIndex:2] setFrame:NSMakeRect(centerX + 20.0, centerY - 10.0, 320.0, 18.0)];
}

- (void)windowDidResize:(NSNotification *)notification
{
    if ([notification object] == self.window) {
        [self syncBookmarkColumnWidth];
        [self positionEmptyStateSubviews];
    }
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
    if ([notification object] == self.window) {
        [self requestMountedStateRefresh];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    (void)notification;
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
}

- (void)installWorkspaceObservers
{
    NSNotificationCenter *workspaceCenter = [[NSWorkspace sharedWorkspace] notificationCenter];

    [workspaceCenter addObserver:self
                        selector:@selector(handleWorkspaceMountChange:)
                            name:NSWorkspaceDidMountNotification
                          object:nil];
    [workspaceCenter addObserver:self
                        selector:@selector(handleWorkspaceMountChange:)
                            name:NSWorkspaceDidUnmountNotification
                          object:nil];
}

- (void)handleWorkspaceMountChange:(NSNotification *)notification
{
    (void)notification;
    [self requestMountedStateRefresh];
}

- (void)syncBookmarkColumnWidth
{
    NSTableColumn *column = [[self.bookmarksTable tableColumns] count] > 0
        ? [[self.bookmarksTable tableColumns] objectAtIndex:0]
        : nil;
    CGFloat width = [[[self.bookmarksTable enclosingScrollView] contentView] bounds].size.width;

    if (!column || width <= 0.0) {
        return;
    }

    [column setWidth:width];
}

- (void)installMainMenu
{
    NSString *appName = [self applicationDisplayName];
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *appRoot = [[NSMenuItem alloc] initWithTitle:appName action:NULL keyEquivalent:@""];
    NSMenuItem *fileRoot = [[NSMenuItem alloc] initWithTitle:@"File" action:NULL keyEquivalent:@""];
    NSMenuItem *connectionRoot = [[NSMenuItem alloc] initWithTitle:@"Actions" action:NULL keyEquivalent:@""];
    NSMenuItem *bookmarksRoot = [[NSMenuItem alloc] initWithTitle:@"Connections" action:NULL keyEquivalent:@""];
    NSMenuItem *windowRoot = [[NSMenuItem alloc] initWithTitle:@"Window" action:NULL keyEquivalent:@""];
    NSMenuItem *helpRoot = [[NSMenuItem alloc] initWithTitle:@"Help" action:NULL keyEquivalent:@""];

    [mainMenu addItem:appRoot];
    [mainMenu addItem:fileRoot];
    [mainMenu addItem:connectionRoot];
    [mainMenu addItem:bookmarksRoot];
    [mainMenu addItem:windowRoot];
    [mainMenu addItem:helpRoot];

    [appRoot setSubmenu:[self applicationMenuWithAppName:appName]];
    [fileRoot setSubmenu:[self fileMenu]];
    [connectionRoot setSubmenu:[self connectionMenu]];
    self.bookmarksMenu = [[NSMenu alloc] initWithTitle:@"Connections"];
    [bookmarksRoot setSubmenu:self.bookmarksMenu];
    [windowRoot setSubmenu:[self windowMenu]];
    [helpRoot setSubmenu:[self helpMenu]];

    [NSApp setMainMenu:mainMenu];
    [NSApp setWindowsMenu:[windowRoot submenu]];
    [NSApp setHelpMenu:[helpRoot submenu]];
}

- (void)installContextualMenu
{
    self.contextualMenu = [[NSMenu alloc] initWithTitle:@"Connection Actions"];
    [self.contextualMenu addItem:[self menuItemWithTitle:@"Connect"
                                                  action:@selector(connectSelectedBookmark:)
                                             keyEquivalent:@""
                                             keyModifiers:0]];
    [self.contextualMenu addItem:[self menuItemWithTitle:@"Disconnect"
                                                  action:@selector(disconnectSelectedBookmark:)
                                             keyEquivalent:@""
                                             keyModifiers:0]];
    [self.contextualMenu addItem:[self menuItemWithTitle:@"List Shares"
                                                  action:@selector(listShares:)
                                             keyEquivalent:@""
                                             keyModifiers:0]];
    [self.contextualMenu addItem:[NSMenuItem separatorItem]];
    [self.contextualMenu addItem:[self menuItemWithTitle:@"Open in Finder"
                                                  action:@selector(openSelectedBookmarkInFinder:)
                                             keyEquivalent:@""
                                             keyModifiers:0]];
    [self.contextualMenu addItem:[self menuItemWithTitle:@"Reveal Mount Point"
                                                  action:@selector(revealSelectedMountPoint:)
                                             keyEquivalent:@""
                                             keyModifiers:0]];
    [self.contextualMenu addItem:[NSMenuItem separatorItem]];
    [self.contextualMenu addItem:[self menuItemWithTitle:@"Edit Connection..."
                                                  action:@selector(editBookmark:)
                                             keyEquivalent:@""
                                             keyModifiers:0]];
    [self.contextualMenu addItem:[self menuItemWithTitle:@"Duplicate Connection"
                                                  action:@selector(duplicateSelectedBookmark:)
                                             keyEquivalent:@""
                                             keyModifiers:0]];
    [self.contextualMenu addItem:[self menuItemWithTitle:@"Remove Connection"
                                                  action:@selector(removeBookmark:)
                                             keyEquivalent:@""
                                             keyModifiers:0]];
    [self.bookmarksTable setMenu:self.contextualMenu];
}

- (NSMenu *)applicationMenuWithAppName:(NSString *)appName
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:appName];
    NSMenuItem *item = nil;

    [menu addItem:[self menuItemWithTitle:[NSString stringWithFormat:@"About %@", appName]
                                   action:@selector(showAboutPanel:)
                              keyEquivalent:@""
                              keyModifiers:0]];
    [menu addItem:[NSMenuItem separatorItem]];
    item = [self menuItemWithTitle:[NSString stringWithFormat:@"Hide %@", appName]
                            action:@selector(hide:)
                       keyEquivalent:@"h"
                       keyModifiers:NSCommandKeyMask];
    [item setTarget:nil];
    [menu addItem:item];
    item = [self menuItemWithTitle:@"Hide Others"
                            action:@selector(hideOtherApplications:)
                       keyEquivalent:@"h"
                       keyModifiers:(NSCommandKeyMask | NSAlternateKeyMask)];
    [item setTarget:nil];
    [menu addItem:item];
    item = [self menuItemWithTitle:@"Show All"
                            action:@selector(unhideAllApplications:)
                       keyEquivalent:@""
                       keyModifiers:0];
    [item setTarget:nil];
    [menu addItem:item];
    [menu addItem:[NSMenuItem separatorItem]];
    item = [self menuItemWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
                            action:@selector(terminate:)
                       keyEquivalent:@"q"
                       keyModifiers:NSCommandKeyMask];
    [item setTarget:nil];
    [menu addItem:item];
    return menu;
}

- (NSMenu *)fileMenu
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"File"];
    [menu addItem:[self menuItemWithTitle:@"New Connection..."
                                   action:@selector(addBookmark:)
                              keyEquivalent:@"n"
                              keyModifiers:NSCommandKeyMask]];
    [menu addItem:[self menuItemWithTitle:@"Edit Connection..."
                                   action:@selector(editBookmark:)
                              keyEquivalent:@"e"
                              keyModifiers:NSCommandKeyMask]];
    [menu addItem:[self menuItemWithTitle:@"Delete Connection"
                                   action:@selector(removeBookmark:)
                              keyEquivalent:@""
                              keyModifiers:0]];
    [menu addItem:[self menuItemWithTitle:@"Duplicate Connection"
                                   action:@selector(duplicateSelectedBookmark:)
                              keyEquivalent:@""
                              keyModifiers:0]];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self menuItemWithTitle:@"Import Connections..."
                                   action:@selector(importConnections:)
                              keyEquivalent:@"i"
                              keyModifiers:NSCommandKeyMask]];
    [menu addItem:[self menuItemWithTitle:@"Export Connection..."
                                   action:@selector(exportSelectedBookmark:)
                              keyEquivalent:@""
                              keyModifiers:0]];
    [menu addItem:[self menuItemWithTitle:@"Export All Connections..."
                                   action:@selector(exportAllBookmarks:)
                              keyEquivalent:@""
                              keyModifiers:0]];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self menuItemWithTitle:@"Close"
                                   action:@selector(closeWindow:)
                              keyEquivalent:@"w"
                              keyModifiers:NSCommandKeyMask]];
    return menu;
}

- (NSMenu *)connectionMenu
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Actions"];
    [menu addItem:[self menuItemWithTitle:@"Connect"
                                   action:@selector(connectSelectedBookmark:)
                              keyEquivalent:@"r"
                              keyModifiers:NSCommandKeyMask]];
    [menu addItem:[self menuItemWithTitle:@"Disconnect"
                                   action:@selector(disconnectSelectedBookmark:)
                              keyEquivalent:@"d"
                              keyModifiers:NSCommandKeyMask]];
    [menu addItem:[self menuItemWithTitle:@"List Shares"
                                   action:@selector(listShares:)
                              keyEquivalent:@"l"
                              keyModifiers:NSCommandKeyMask]];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self menuItemWithTitle:@"Open in Finder"
                                   action:@selector(openSelectedBookmarkInFinder:)
                              keyEquivalent:@"o"
                              keyModifiers:NSCommandKeyMask]];
    [menu addItem:[self menuItemWithTitle:@"Reveal Mount Point"
                                   action:@selector(revealSelectedMountPoint:)
                              keyEquivalent:@""
                              keyModifiers:0]];
    return menu;
}

- (NSMenu *)windowMenu
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Window"];
    NSMenuItem *item = [self menuItemWithTitle:@"Minimize"
                                        action:@selector(performMiniaturize:)
                                   keyEquivalent:@"m"
                                   keyModifiers:NSCommandKeyMask];
    [item setTarget:nil];
    [menu addItem:item];
    item = [self menuItemWithTitle:@"Bring All to Front"
                            action:@selector(arrangeInFront:)
                       keyEquivalent:@""
                       keyModifiers:0];
    [item setTarget:nil];
    [menu addItem:item];
    return menu;
}

- (NSMenu *)helpMenu
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Help"];
    [menu addItem:[self menuItemWithTitle:@"SMB2 FUSE Help"
                                   action:@selector(showHelpPanel:)
                              keyEquivalent:@""
                              keyModifiers:0]];
    [menu addItem:[self menuItemWithTitle:@"Command Line Help"
                                   action:@selector(showCommandLineHelp:)
                              keyEquivalent:@""
                              keyModifiers:0]];
    return menu;
}

- (NSMenuItem *)menuItemWithTitle:(NSString *)title
                           action:(SEL)action
                      keyEquivalent:(NSString *)keyEquivalent
                      keyModifiers:(NSUInteger)keyModifiers
{
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:keyEquivalent ?: @""];
    [item setTarget:self];
    [item setKeyEquivalentModifierMask:keyModifiers];
    return item;
}

- (NSTableColumn *)bookmarkColumn
{
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"bookmark"];
    [column setWidth:700.0];
    [column setResizingMask:NSTableColumnAutoresizingMask];
    return column;
}

- (NSTextField *)labelWithString:(NSString *)string frame:(NSRect)frame bold:(BOOL)bold
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    [label setBordered:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setDrawsBackground:NO];
    [label setStringValue:string ?: @""];
    [label setFont:bold ? [NSFont boldSystemFontOfSize:12.0] : [NSFont systemFontOfSize:12.0]];
    return label;
}

- (NSButton *)buttonWithTitle:(NSString *)title frame:(NSRect)frame action:(SEL)action
{
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    [button setTitle:title];
    [button setBezelStyle:NSRoundedBezelStyle];
    [button setTarget:self];
    [button setAction:action];
    return button;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    (void)tableView;
    return (NSInteger)[self.bookmarks count];
}

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row
{
    (void)tableColumn;
    (void)tableView;

    SMBBookmarkCellView *cell = [self.bookmarksTable makeViewWithIdentifier:@"bookmark-cell" owner:self];
    if (!cell) {
        cell = [[SMBBookmarkCellView alloc] initWithFrame:NSMakeRect(0.0, 0.0, [self.bookmarksTable bounds].size.width, 60.0)];
        [cell setIdentifier:@"bookmark-cell"];
    }

    SMBConnection *bookmark = [self.bookmarks objectAtIndex:(NSUInteger)row];
    NSString *title = [self bookmarkDisplayName:bookmark];
    NSString *mountpoint = bookmark.mountedPath ?: @"";
    NSImage *icon = [NSImage imageNamed:NSImageNameNetwork];

    [cell.bookmarkIconView setImage:icon];
    [cell.titleField setStringValue:title];
    [cell.subtitleField setStringValue:[bookmark subtitleText] ?: @""];
    [cell.detailField setStringValue:[bookmark detailText] ?: @""];
    [cell.mountedField setStringValue:[mountpoint length] > 0 ? @"Connected" : @"Not connected"];
    [cell updateTextColors];

    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    (void)notification;
    if ([self.bookmarksTable isKindOfClass:[SMBBookmarkTableView class]]) {
        [(SMBBookmarkTableView *)self.bookmarksTable setContextualRow:[self.bookmarksTable selectedRow]];
    }
    [self refreshButtons];
}

- (IBAction)addBookmark:(id)sender
{
    (void)sender;
    [self openEditorForBookmark:nil atIndex:-1];
}

- (IBAction)duplicateSelectedBookmark:(id)sender
{
    (void)sender;
    NSInteger row = [self selectedBookmarkRow];
    SMBConnection *bookmark = [self selectedBookmark];
    SMBConnection *copy = nil;
    NSString *originalName = nil;

    if (!bookmark) {
        [self setStatus:@"Select a connection to duplicate."];
        return;
    }

    copy = [bookmark copy];
    originalName = [self bookmarkDisplayName:bookmark];
    copy.uuid = [SMBConnection generatedUUID];
    copy.name = [NSString stringWithFormat:@"%@ Copy", originalName];
    copy.mountedPath = nil;

    [self.bookmarks insertObject:copy atIndex:(NSUInteger)(row + 1)];
    [self persistBookmarks];
    [self reloadBookmarkList];
    [self.bookmarksTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)(row + 1)] byExtendingSelection:NO];
    [self setStatus:@"Connection duplicated."];
}

- (IBAction)editBookmark:(id)sender
{
    (void)sender;
    NSInteger row = [self selectedBookmarkRow];
    if (row < 0) {
        [self setStatus:@"Select a connection to edit."];
        return;
    }

    [self openEditorForBookmark:[self.bookmarks objectAtIndex:(NSUInteger)row] atIndex:row];
}

- (IBAction)removeBookmark:(id)sender
{
    (void)sender;
    NSInteger row = [self selectedBookmarkRow];
    if (row < 0) {
        [self setStatus:@"Select a connection to remove."];
        return;
    }

    SMBConnection *bookmark = [self.bookmarks objectAtIndex:(NSUInteger)row];
    bookmark.mountedPath = nil;

    [self.bookmarks removeObjectAtIndex:(NSUInteger)row];
    [self persistBookmarks];
    [self reloadBookmarkList];
    [self setStatus:@"Connection removed."];
}

- (IBAction)connectSelectedBookmark:(id)sender
{
    (void)sender;
    [self requestMountedStateRefresh];
    if (self.taskRunning) {
        [self setStatus:@"A task is already running."];
        return;
    }

    SMBConnection *bookmark = [self selectedBookmark];
    if (!bookmark) {
        [self setStatus:@"Select a connection to connect."];
        return;
    }

    if ([self isBookmarkMounted:bookmark]) {
        [self setStatus:@"This connection is already connected."];
        return;
    }

    NSString *server = bookmark.server ?: @"";
    NSString *share = bookmark.share ?: @"";
    NSString *user = bookmark.user ?: @"";
    NSString *domain = bookmark.domain ?: @"";
    NSString *executablePath = [self smb2fsExecutablePath];
    NSDictionary *passwordDecision = nil;
    NSString *password = nil;
    BOOL shouldRememberPassword = NO;

    if ([server length] == 0 || [share length] == 0) {
        [self setStatus:@"The selected connection needs both server and share."];
        return;
    }
    if ([executablePath length] == 0) {
        [self setStatus:@"Unable to locate smb2fs. Build the CLI first, then rebuild the app."];
        return;
    }

    if ([user length] > 0) {
        passwordDecision = [self preparedPasswordDecisionForServer:server
                                                              user:user
                                                            domain:domain
                                                             title:@"Password Required"
                                                           message:[NSString stringWithFormat:@"Enter the password for %@ on %@.", user, server]];
        if (!passwordDecision) {
            [self setStatus:@"Connection cancelled."];
            return;
        }
        password = [passwordDecision objectForKey:@"password"] ?: @"";
        shouldRememberPassword = [[passwordDecision objectForKey:@"remember"] boolValue];
    }

    NSMutableArray *arguments = [self mountArgumentsForConnection:bookmark];

    [self setControlsEnabled:NO];
    [self setStatus:[NSString stringWithFormat:@"Connecting to %@...", [self bookmarkDisplayName:bookmark]]];
    [self.taskRunner runCommandAtPath:executablePath
                            arguments:arguments
                          stdinString:password
                           completion:^(int status, NSString *output) {
        [self setControlsEnabled:YES];

        if (status == 0) {
            NSString *mountpoint = [self mountpointFromOutput:output];
            NSString *mountStatus = nil;
            if ([mountpoint length] == 0) {
                mountpoint = [self bestGuessMountpointForBookmark:bookmark];
            }
            bookmark.mountedPath = [mountpoint length] > 0 ? mountpoint : nil;
            [self reloadBookmarkList];
            mountStatus = [NSString stringWithFormat:@"Mounted %@%@%@.",
                           [self bookmarkDisplayName:bookmark],
                           [mountpoint length] > 0 ? @" at " : @"",
                           [mountpoint length] > 0 ? mountpoint : @""];
            if (shouldRememberPassword) {
                OSStatus saveStatus = [self.keychainStore storePassword:password server:server user:user domain:domain];
                if (saveStatus != errSecSuccess) {
                    [self showTextPanelWithTitle:@"Keychain Save Failed"
                                            text:[NSString stringWithFormat:@"The connection succeeded, but the password could not be saved in the Mac keychain.\n\n%@",
                                                  [self.keychainStore errorStringForStatus:saveStatus]]];
                    mountStatus = [mountStatus stringByAppendingString:@" Password was not saved."];
                }
            }
            [self setStatus:mountStatus];
        } else {
            [self showTextPanelWithTitle:@"Connection Failed" text:output];
            [self setStatus:@"Connection failed."];
        }
    }];
}

- (IBAction)disconnectSelectedBookmark:(id)sender
{
    (void)sender;
    [self requestMountedStateRefresh];
    if (self.taskRunning) {
        [self setStatus:@"A task is already running."];
        return;
    }

    SMBConnection *bookmark = [self selectedBookmark];
    if (!bookmark) {
        [self setStatus:@"Select a connection to disconnect."];
        return;
    }

    if (![self isBookmarkMounted:bookmark]) {
        [self setStatus:@"This connection is not currently connected."];
        return;
    }

    NSString *mountpoint = [self mountedPathForBookmark:bookmark];
    if ([mountpoint length] == 0) {
        mountpoint = [self bestGuessMountpointForBookmark:bookmark];
    }
    if ([mountpoint length] == 0) {
        [self setStatus:@"This connection does not have a known mount point."];
        return;
    }

    [self setControlsEnabled:NO];
    [self setStatus:[NSString stringWithFormat:@"Disconnecting %@...", [self bookmarkDisplayName:bookmark]]];
    [self.taskRunner runCommandAtPath:@"/sbin/umount"
                            arguments:[NSArray arrayWithObject:mountpoint]
                          stdinString:nil
                           completion:^(int status, NSString *output) {
        [self setControlsEnabled:YES];

        if (status == 0) {
            bookmark.mountedPath = nil;
            [self reloadBookmarkList];
            [self setStatus:@"Disconnected."];
        } else {
            [self showTextPanelWithTitle:@"Disconnect Failed" text:output];
            [self setStatus:@"Disconnect failed."];
        }
    }];
}

- (IBAction)listShares:(id)sender
{
    (void)sender;
    [self requestMountedStateRefresh];
    if (self.taskRunning) {
        [self setStatus:@"A task is already running."];
        return;
    }

    SMBConnection *bookmark = [self selectedBookmark];
    NSInteger row = [self selectedBookmarkRow];
    if (!bookmark) {
        [self setStatus:@"Select a connection first."];
        return;
    }

    NSString *server = bookmark.server ?: @"";
    NSString *user = bookmark.user ?: @"";
    NSString *domain = bookmark.domain ?: @"";
    NSString *executablePath = [self smb2fsExecutablePath];
    NSDictionary *passwordDecision = nil;
    NSString *password = nil;
    BOOL shouldRememberPassword = NO;

    if ([server length] == 0) {
        [self setStatus:@"The selected connection needs a server."];
        return;
    }
    if ([executablePath length] == 0) {
        [self setStatus:@"Unable to locate smb2fs. Build the CLI first, then rebuild the app."];
        return;
    }

    if ([user length] > 0) {
        passwordDecision = [self preparedPasswordDecisionForServer:server
                                                              user:user
                                                            domain:domain
                                                             title:@"Password Required"
                                                           message:[NSString stringWithFormat:@"Enter the password for %@ on %@.", user, server]];
        if (!passwordDecision) {
            [self setStatus:@"Share listing cancelled."];
            return;
        }
        password = [passwordDecision objectForKey:@"password"] ?: @"";
        shouldRememberPassword = [[passwordDecision objectForKey:@"remember"] boolValue];
    }

    NSMutableArray *arguments = [self listSharesArgumentsForConnection:bookmark];

    [self setControlsEnabled:NO];
    [self setStatus:[NSString stringWithFormat:@"Listing shares for %@...", server]];
    [self.taskRunner runCommandAtPath:executablePath
                            arguments:arguments
                          stdinString:password
                           completion:^(int status, NSString *output) {
        [self setControlsEnabled:YES];

        if (status == 0) {
            NSArray *shares = [self parseShareNamesFromOutput:output];
            if (shouldRememberPassword) {
                OSStatus saveStatus = [self.keychainStore storePassword:password server:server user:user domain:domain];
                if (saveStatus != errSecSuccess) {
                    [self showTextPanelWithTitle:@"Keychain Save Failed"
                                            text:[NSString stringWithFormat:@"The share listing succeeded, but the password could not be saved in the Mac keychain.\n\n%@",
                                                  [self.keychainStore errorStringForStatus:saveStatus]]];
                }
            }
            if ([shares count] == 0) {
                [self showTextPanelWithTitle:@"Visible Shares" text:@"No browseable shares were returned."];
                [self setStatus:@"No shares were returned."];
            } else {
                [self chooseShareFromArray:shares forBookmarkAtRow:row];
            }
        } else {
            [self showTextPanelWithTitle:@"Share Listing Failed" text:output];
            [self setStatus:@"Share listing failed."];
        }
    }];
}

- (IBAction)activateSelectedBookmark:(id)sender
{
    (void)sender;
    [self requestMountedStateRefresh];

    SMBConnection *bookmark = [self selectedBookmark];
    if (!bookmark) {
        [self setStatus:@"Select a connection first."];
        return;
    }

    if ([self isBookmarkMounted:bookmark]) {
        [self openMountedBookmarkInFinder:bookmark];
    } else {
        [self connectSelectedBookmark:nil];
    }
}

- (IBAction)openSelectedBookmarkInFinder:(id)sender
{
    (void)sender;
    [self requestMountedStateRefresh];
    SMBConnection *bookmark = [self selectedBookmark];

    if (!bookmark) {
        [self setStatus:@"Select a connection first."];
        return;
    }

    [self openMountedBookmarkInFinder:bookmark];
}

- (IBAction)revealSelectedMountPoint:(id)sender
{
    (void)sender;
    [self requestMountedStateRefresh];
    SMBConnection *bookmark = [self selectedBookmark];
    NSString *mountpoint = nil;

    if (!bookmark) {
        [self setStatus:@"Select a connection first."];
        return;
    }

    mountpoint = [self mountedPathForBookmark:bookmark];
    if ([mountpoint length] == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:mountpoint]) {
        [self setStatus:@"This connection is not currently connected."];
        return;
    }

    if ([[NSWorkspace sharedWorkspace] openFile:mountpoint]) {
        [self setStatus:[NSString stringWithFormat:@"Opened %@ mount point in Finder.", [self bookmarkDisplayName:bookmark]]];
    } else {
        [self setStatus:@"Finder could not open the mount point."];
    }
}

- (IBAction)showAboutPanel:(id)sender
{
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 420.0, 250.0)
                                                styleMask:(NSTitledWindowMask | NSClosableWindowMask)
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    NSView *content = [panel contentView];
    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(162.0, 150.0, 96.0, 64.0)];
    NSTextField *title = [self labelWithString:@"SMB2 FUSE"
                                         frame:NSMakeRect(90.0, 112.0, 240.0, 28.0)
                                          bold:YES];
    NSTextField *subtitle = [self labelWithString:@"Lion-friendly connection manager for smb2fs"
                                            frame:NSMakeRect(38.0, 84.0, 344.0, 20.0)
                                             bold:NO];
    NSTextField *author = [self labelWithString:@"Created by Gabriele Pintus"
                                          frame:NSMakeRect(100.0, 58.0, 220.0, 18.0)
                                           bold:NO];
    NSTextView *linkView = [self aboutLinkViewWithFrame:NSMakeRect(40.0, 28.0, 340.0, 22.0)
                                              urlString:@"https://github.com/GabrielePintus/smb2fuse"];
    NSButton *okButton = [self buttonWithTitle:@"OK"
                                         frame:NSMakeRect(170.0, 6.0, 80.0, 28.0)
                                        action:@selector(dismissSimplePanel:)];

    (void)sender;
    [panel setTitle:@"About SMB2 FUSE"];
    [panel center];
    [iconView setImage:[NSApp applicationIconImage]];
    [iconView setImageScaling:NSImageScaleProportionallyUpOrDown];

    [title setAlignment:NSCenterTextAlignment];
    [title setFont:[NSFont boldSystemFontOfSize:18.0]];
    [subtitle setAlignment:NSCenterTextAlignment];
    [subtitle setFont:[NSFont systemFontOfSize:13.0]];
    [author setAlignment:NSCenterTextAlignment];
    [author setFont:[NSFont systemFontOfSize:12.0]];

    [content addSubview:iconView];
    [content addSubview:title];
    [content addSubview:subtitle];
    [content addSubview:author];
    [content addSubview:linkView];
    [content addSubview:okButton];

    [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
}

- (IBAction)showHelpPanel:(id)sender
{
    (void)sender;
    [self showTextPanelWithTitle:@"SMB2 FUSE Help"
                            text:@"SMB2 FUSE manages saved SMB connections and launches the smb2fs CLI for you.\n\nUse File > New Connection to create a saved connection, File > Import Connections to bring in JSON exports, and File > Export to share or back up your saved connections.\n\nIf a connection uses a username, you can optionally remember its password in your Mac keychain. Saved passwords are reused automatically and are never exported.\n\nUse Actions > List Shares to browse shares on a host, Actions > Connect to mount the selected connection, and Actions > Disconnect to unmount it.\n\nDouble-click an unmounted connection to connect. Double-click a mounted connection to open it in Finder."];
}

- (IBAction)showCommandLineHelp:(id)sender
{
    NSString *path = [self smb2fsExecutablePath];
    NSString *output = nil;
    int status = -1;

    (void)sender;
    output = [self.taskRunner outputForCommandAtPath:path arguments:[NSArray arrayWithObject:@"--help"] terminationStatus:&status];
    if (status != 0 || [output length] == 0) {
        output = @"Usage: smb2fs [mountpoint] --server HOST --share SHARE [--user USER]\n       [--password PASS | --passfd FD | --password-prompt]\n       [--domain DOMAIN] [--volname NAME] [FUSE options]\n\nKey options:\n  --list-shares\n  --server HOST\n  --share SHARE\n  --user USER\n  --domain DOMAIN\n  --volname NAME\n  --help";
    }
    [self showTextPanelWithTitle:@"Command Line Help" text:output];
}

- (IBAction)importConnections:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    NSData *data = nil;
    NSError *error = nil;
    NSDictionary *document = nil;
    NSArray *connections = nil;
    NSMutableArray *normalized = [NSMutableArray array];
    NSMutableArray *issues = [NSMutableArray array];
    NSUInteger importCount = 0;
    NSString *summary = nil;

    (void)sender;
    if (self.taskRunning) {
        [self setStatus:@"A task is already running."];
        return;
    }

    [panel setCanChooseDirectories:NO];
    [panel setAllowsMultipleSelection:NO];
    [panel setCanChooseFiles:YES];
    [panel setAllowedFileTypes:[NSArray arrayWithObject:@"json"]];

    if ([panel runModal] != NSFileHandlingPanelOKButton) {
        [self setStatus:@"Import cancelled."];
        return;
    }

    data = [NSData dataWithContentsOfURL:[panel URL] options:0 error:&error];
    if (!data) {
        [self showTextPanelWithTitle:@"Import Failed"
                                text:[NSString stringWithFormat:@"Could not read the selected file.\n\n%@",
                                      [error localizedDescription] ?: @"Unknown error."]];
        [self setStatus:@"Import failed."];
        return;
    }

    document = [self connectionExchangeDocumentFromData:data error:&error];
    if (!document) {
        [self showTextPanelWithTitle:@"Import Failed"
                                text:[NSString stringWithFormat:@"The selected file is not a valid SMB2 FUSE connections export.\n\n%@",
                                      [error localizedDescription] ?: @"Unknown error."]];
        [self setStatus:@"Import failed."];
        return;
    }

    connections = [document objectForKey:@"connections"];
    for (NSDictionary *entry in connections) {
        SMBConnection *bookmark = [self normalizedImportedBookmarkFromDictionary:entry issues:issues];
        if (bookmark) {
            [normalized addObject:bookmark];
        }
    }

    if ([normalized count] == 0) {
        summary = [issues count] > 0
            ? [issues componentsJoinedByString:@"\n"]
            : @"No valid connections were found in the selected file.";
        [self showTextPanelWithTitle:@"Nothing Imported" text:summary];
        [self setStatus:@"No connections were imported."];
        return;
    }

    if ([normalized count] > 1) {
        NSInteger choice = [self importChoiceForConnectionNames:[normalized valueForKey:@"name"]];
        if (choice == NSAlertSecondButtonReturn) {
            SMBConnection *selected = [self chooseImportedConnectionFromArray:normalized];
            if (!selected) {
                [self setStatus:@"Import cancelled."];
                return;
            }
            [normalized removeAllObjects];
            [normalized addObject:selected];
        } else if (choice != NSAlertFirstButtonReturn) {
            [self setStatus:@"Import cancelled."];
            return;
        }
    }

    for (SMBConnection *bookmark in normalized) {
        [self.bookmarks addObject:bookmark];
    }
    importCount = [normalized count];

    [self persistBookmarks];
    [self reloadBookmarkList];
    if ([self.bookmarks count] > 0) {
        NSUInteger lastIndex = [self.bookmarks count] - 1;
        [self.bookmarksTable selectRowIndexes:[NSIndexSet indexSetWithIndex:lastIndex] byExtendingSelection:NO];
        [self.bookmarksTable scrollRowToVisible:(NSInteger)lastIndex];
    }

    if ([issues count] > 0) {
        NSString *title = importCount == 1 ? @"Imported 1 Connection" : [NSString stringWithFormat:@"Imported %lu Connections", (unsigned long)importCount];
        NSString *detail = [NSString stringWithFormat:@"Some entries were skipped:\n\n%@",
                            [issues componentsJoinedByString:@"\n"]];
        [self showTextPanelWithTitle:title text:detail];
    }

    [self setStatus:[NSString stringWithFormat:@"Imported %lu connection%@.",
                     (unsigned long)importCount,
                     importCount == 1 ? @"" : @"s"]];
}

- (IBAction)exportSelectedBookmark:(id)sender
{
    SMBConnection *bookmark = nil;

    (void)sender;
    if (self.taskRunning) {
        [self setStatus:@"A task is already running."];
        return;
    }

    bookmark = [self selectedBookmark];
    if (!bookmark) {
        [self setStatus:@"Select a connection to export."];
        return;
    }

    [self exportBookmarks:[NSArray arrayWithObject:bookmark]
              defaultName:[NSString stringWithFormat:@"%@.json", [self safeFilenameForConnectionName:[self bookmarkDisplayName:bookmark]]]
              statusLabel:@"connection"];
}

- (IBAction)exportAllBookmarks:(id)sender
{
    (void)sender;
    if (self.taskRunning) {
        [self setStatus:@"A task is already running."];
        return;
    }

    if ([self.bookmarks count] == 0) {
        [self setStatus:@"There are no connections to export."];
        return;
    }

    [self exportBookmarks:self.bookmarks
              defaultName:@"SMB2-FUSE-Connections.json"
              statusLabel:@"connections"];
}

- (IBAction)selectBookmarkFromMenuItem:(id)sender
{
    NSMenuItem *item = (NSMenuItem *)sender;
    NSString *uuid = [item representedObject];
    NSInteger row = [self rowForBookmarkUUID:uuid];

    if (row < 0) {
        return;
    }

    [self.bookmarksTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [self.bookmarksTable scrollRowToVisible:row];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self refreshButtons];
}

- (IBAction)closeWindow:(id)sender
{
    (void)sender;
    [self.window performClose:nil];
}

- (void)openEditorForBookmark:(SMBConnection *)bookmark atIndex:(NSInteger)index
{
    SMBConnection *source = bookmark ?: [[SMBConnection alloc] init];
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 390.0, 340.0)
                                                styleMask:(NSTitledWindowMask | NSClosableWindowMask)
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    NSView *contentView = [panel contentView];

    [panel setTitle:index >= 0 ? @"Edit Connection" : @"New Connection"];
    [panel center];

    [self editorFieldInView:contentView title:@"Name" y:262.0 value:source.name hint:@"Office NAS" tag:kSMBEditorNameTag];
    [self editorFieldInView:contentView title:@"Server" y:228.0 value:source.server hint:@"server.local or 192.168.1.52" tag:kSMBEditorServerTag];
    [self editorFieldInView:contentView title:@"User" y:194.0 value:source.user hint:@"Optional username" tag:kSMBEditorUserTag];
    [self editorFieldInView:contentView title:@"Domain" y:160.0 value:source.domain hint:@"Optional domain" tag:kSMBEditorDomainTag];
    [self editorShareFieldInView:contentView y:126.0 value:source.share hint:@"SharedFolder"];

    NSTextField *passwordState = [self labelWithString:@""
                                                 frame:NSMakeRect(18.0, 98.0, 220.0, 16.0)
                                                  bold:NO];
    [passwordState setTag:kSMBEditorPasswordStateTag];
    [passwordState setTextColor:[NSColor grayColor]];
    [passwordState setFont:[NSFont systemFontOfSize:11.0]];
    [contentView addSubview:passwordState];

    NSButton *forgetPasswordButton = [self buttonWithTitle:@"Forget Saved Password"
                                                     frame:NSMakeRect(242.0, 92.0, 134.0, 24.0)
                                                    action:@selector(forgetSavedPasswordFromEditor:)];
    [forgetPasswordButton setTag:kSMBEditorForgetPasswordTag];
    [contentView addSubview:forgetPasswordButton];

    NSTextField *errorLabel = [self labelWithString:@""
                                              frame:NSMakeRect(18.0, 68.0, 354.0, 18.0)
                                               bold:NO];
    [errorLabel setTag:kSMBEditorErrorTag];
    [errorLabel setTextColor:[NSColor colorWithCalibratedRed:0.74 green:0.14 blue:0.14 alpha:1.0]];
    [errorLabel setFont:[NSFont boldSystemFontOfSize:11.0]];
    [contentView addSubview:errorLabel];

    NSTextField *note = [self labelWithString:@"Passwords are stored in your Mac keychain and are never exported."
                                        frame:NSMakeRect(18.0, 36.0, 354.0, 28.0)
                                         bold:NO];
    [note setTextColor:[NSColor grayColor]];
    [note setFont:[NSFont systemFontOfSize:11.0]];
    [[note cell] setWraps:YES];
    [[note cell] setLineBreakMode:NSLineBreakByWordWrapping];
    [contentView addSubview:note];

    NSButton *cancelButton = [self buttonWithTitle:@"Cancel"
                                             frame:NSMakeRect(214.0, 8.0, 78.0, 28.0)
                                            action:@selector(cancelEditorPanel:)];
    NSButton *saveButton = [self buttonWithTitle:@"Save"
                                           frame:NSMakeRect(298.0, 8.0, 78.0, 28.0)
                                          action:@selector(saveEditorPanel:)];
    [saveButton setKeyEquivalent:@"\r"];
    [contentView addSubview:cancelButton];
    [contentView addSubview:saveButton];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(editorTextDidChange:)
                                                 name:NSControlTextDidChangeNotification
                                               object:nil];
    [self updateEditorCredentialControlsForWindow:panel];

    NSInteger response = [NSApp runModalForWindow:panel];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSControlTextDidChangeNotification
                                                  object:nil];
    if (response != NSAlertFirstButtonReturn) {
        return;
    }

    SMBConnection *updated = [[SMBConnection alloc] init];
    updated.name = [self editorValueForTag:kSMBEditorNameTag inWindow:panel];
    updated.server = [self editorValueForTag:kSMBEditorServerTag inWindow:panel];
    updated.share = [self editorValueForTag:kSMBEditorShareTag inWindow:panel];
    updated.user = [self editorValueForTag:kSMBEditorUserTag inWindow:panel];
    updated.domain = [self editorValueForTag:kSMBEditorDomainTag inWindow:panel];

    if (index >= 0) {
        updated.uuid = source.uuid;
        updated.mountedPath = source.mountedPath;
        [self.bookmarks replaceObjectAtIndex:(NSUInteger)index withObject:updated];
    } else {
        updated.uuid = [SMBConnection generatedUUID];
        [self.bookmarks addObject:updated];
    }

    [self persistBookmarks];
    [self reloadBookmarkList];
    [self setStatus:index >= 0 ? @"Connection updated." : @"Connection added."];
}

- (NSTextField *)editorFieldInView:(NSView *)view
                             title:(NSString *)title
                                 y:(CGFloat)y
                             value:(NSString *)value
                              hint:(NSString *)hint
                               tag:(NSInteger)tag
{
    NSTextField *label = [self labelWithString:title frame:NSMakeRect(10.0, y + 4.0, 88.0, 18.0) bold:NO];
    [view addSubview:label];

    SMBHintTextField *field = [[SMBHintTextField alloc] initWithFrame:NSMakeRect(102.0, y, 270.0, 22.0)];
    [field setTag:tag];
    [field setHintString:hint ?: @""];
    [field setStringValue:value ?: @""];
    [view addSubview:field];
    return field;
}

- (NSTextField *)editorShareFieldInView:(NSView *)view
                                     y:(CGFloat)y
                                 value:(NSString *)value
                                  hint:(NSString *)hint
{
    NSTextField *label = [self labelWithString:@"Share" frame:NSMakeRect(10.0, y + 4.0, 88.0, 18.0) bold:NO];
    SMBHintTextField *field = [[SMBHintTextField alloc] initWithFrame:NSMakeRect(102.0, y, 182.0, 22.0)];
    NSButton *button = [self buttonWithTitle:@"Browse..."
                                       frame:NSMakeRect(292.0, y - 1.0, 80.0, 24.0)
                                      action:@selector(browseSharesFromEditor:)];

    [field setTag:kSMBEditorShareTag];
    [field setHintString:hint ?: @""];
    [field setStringValue:value ?: @""];
    [button setTag:kSMBEditorBrowseSharesTag];

    [view addSubview:label];
    [view addSubview:field];
    [view addSubview:button];
    return field;
}

- (IBAction)browseSharesFromEditor:(id)sender
{
    NSWindow *window = [sender window];
    NSTextField *serverField = (NSTextField *)[[window contentView] viewWithTag:kSMBEditorServerTag];
    NSTextField *shareField = (NSTextField *)[[window contentView] viewWithTag:kSMBEditorShareTag];
    NSTextField *nameField = (NSTextField *)[[window contentView] viewWithTag:kSMBEditorNameTag];
    NSTextField *userField = (NSTextField *)[[window contentView] viewWithTag:kSMBEditorUserTag];
    NSTextField *domainField = (NSTextField *)[[window contentView] viewWithTag:kSMBEditorDomainTag];
    NSTextField *errorLabel = (NSTextField *)[[window contentView] viewWithTag:kSMBEditorErrorTag];
    NSString *server = [self trimmedString:[serverField stringValue]];
    NSString *user = [self trimmedString:[userField stringValue]];
    NSString *domain = [self trimmedString:[domainField stringValue]];
    NSString *executablePath = [self smb2fsExecutablePath];
    NSDictionary *passwordDecision = nil;
    NSString *password = nil;
    BOOL shouldRememberPassword = NO;
    NSMutableArray *arguments = nil;

    if ([server length] == 0) {
        [self setEditorField:serverField invalid:YES];
        [errorLabel setStringValue:@"Enter a server first, then browse shares."];
        [window makeFirstResponder:serverField];
        return;
    }
    if (![self isValidServerValue:server]) {
        [self setEditorField:serverField invalid:YES];
        [errorLabel setStringValue:@"Server must be a valid hostname or IP address."];
        [window makeFirstResponder:serverField];
        return;
    }

    [self setEditorField:serverField invalid:NO];
    [errorLabel setStringValue:@""];

    if ([executablePath length] == 0) {
        [errorLabel setStringValue:@"smb2fs is not available. Build the CLI first, then rebuild the app."];
        return;
    }
    if (self.editorBrowseInProgress) {
        return;
    }

    if ([user length] > 0) {
        passwordDecision = [self preparedPasswordDecisionForServer:server
                                                              user:user
                                                            domain:domain
                                                             title:@"Password Required"
                                                           message:[NSString stringWithFormat:@"Enter the password for %@ on %@.", user, server]];
        if (!passwordDecision) {
            [errorLabel setStringValue:@"Share listing cancelled."];
            return;
        }
        password = [passwordDecision objectForKey:@"password"] ?: @"";
        shouldRememberPassword = [[passwordDecision objectForKey:@"remember"] boolValue];
    }

    arguments = [self listSharesArgumentsForServer:server user:user domain:domain];
    self.editorBrowseInProgress = YES;
    [(NSButton *)sender setEnabled:NO];
    [errorLabel setStringValue:@"Listing shares..."];

    [self.taskRunner runCommandAtPath:executablePath
                            arguments:arguments
                          stdinString:password
                           completion:^(int asyncStatus, NSString *asyncOutput) {
        NSString *output = asyncOutput ?: @"";
        NSArray *shares = nil;

        self.editorBrowseInProgress = NO;
        [(NSButton *)sender setEnabled:YES];

        if (asyncStatus != 0) {
            [self showTextPanelWithTitle:@"Share Listing Failed" text:output];
            [errorLabel setStringValue:@"Could not list shares for that server."];
            return;
        }

        if (shouldRememberPassword) {
            OSStatus saveStatus = [self.keychainStore storePassword:password server:server user:user domain:domain];
            if (saveStatus != errSecSuccess) {
                [self showTextPanelWithTitle:@"Keychain Save Failed"
                                        text:[NSString stringWithFormat:@"The share listing succeeded, but the password could not be saved in the Mac keychain.\n\n%@",
                                              [self.keychainStore errorStringForStatus:saveStatus]]];
            }
        }

        shares = [self parseShareNamesFromOutput:output];
        if ([shares count] == 0) {
            [self showTextPanelWithTitle:@"Visible Shares" text:@"No browseable shares were returned."];
            [errorLabel setStringValue:@"No browseable shares were returned."];
            return;
        }

        if (![self chooseShareFromArray:shares intoField:shareField nameField:nameField]) {
            [errorLabel setStringValue:@"Share selection cancelled."];
            return;
        }

        [self setEditorField:shareField invalid:NO];
        [errorLabel setStringValue:@""];
        [self updateEditorCredentialControlsForWindow:window];
    }];
}

- (IBAction)saveEditorPanel:(id)sender
{
    NSWindow *window = [sender window];

    if (![self validateEditorWindow:window]) {
        return;
    }

    [NSApp stopModalWithCode:NSAlertFirstButtonReturn];
    [window orderOut:nil];
}

- (IBAction)cancelEditorPanel:(id)sender
{
    NSWindow *window = [sender window];
    [NSApp stopModalWithCode:NSAlertSecondButtonReturn];
    [window orderOut:nil];
}

- (IBAction)dismissSimplePanel:(id)sender
{
    NSWindow *window = [sender window];
    [NSApp stopModal];
    [window orderOut:nil];
}

- (IBAction)confirmSimplePanel:(id)sender
{
    NSWindow *window = [sender window];
    [NSApp stopModalWithCode:NSAlertFirstButtonReturn];
    [window orderOut:nil];
}

- (IBAction)forgetSavedPasswordFromEditor:(id)sender
{
    NSWindow *window = [sender window];
    NSTextField *serverField = (NSTextField *)[[window contentView] viewWithTag:kSMBEditorServerTag];
    NSTextField *userField = (NSTextField *)[[window contentView] viewWithTag:kSMBEditorUserTag];
    NSTextField *domainField = (NSTextField *)[[window contentView] viewWithTag:kSMBEditorDomainTag];
    NSTextField *errorLabel = (NSTextField *)[[window contentView] viewWithTag:kSMBEditorErrorTag];
    NSString *server = [self trimmedString:[serverField stringValue]];
    NSString *user = [self trimmedString:[userField stringValue]];
    NSString *domain = [self trimmedString:[domainField stringValue]];
    OSStatus status = noErr;

    if ([server length] == 0 || [user length] == 0) {
        [self updateEditorCredentialControlsForWindow:window];
        return;
    }

    status = [self.keychainStore deletePasswordForServer:server user:user domain:domain];
    if (status != errSecSuccess && status != errSecItemNotFound) {
        [errorLabel setStringValue:[NSString stringWithFormat:@"Could not remove the saved password: %@",
                                    [self.keychainStore errorStringForStatus:status]]];
        return;
    }

    [errorLabel setStringValue:@""];
    [self updateEditorCredentialControlsForWindow:window];
}

- (void)editorTextDidChange:(NSNotification *)notification
{
    id object = [notification object];
    NSWindow *window = nil;

    if (![object isKindOfClass:[NSControl class]]) {
        return;
    }

    window = [(NSControl *)object window];
    if (![window isKindOfClass:[NSPanel class]]) {
        return;
    }

    if ([[window contentView] viewWithTag:kSMBEditorServerTag] == nil) {
        return;
    }

    [self updateEditorCredentialControlsForWindow:window];
}

- (void)updateEditorCredentialControlsForWindow:(NSWindow *)window
{
    NSTextField *serverField = (NSTextField *)[[window contentView] viewWithTag:kSMBEditorServerTag];
    NSTextField *userField = (NSTextField *)[[window contentView] viewWithTag:kSMBEditorUserTag];
    NSTextField *domainField = (NSTextField *)[[window contentView] viewWithTag:kSMBEditorDomainTag];
    NSTextField *stateLabel = (NSTextField *)[[window contentView] viewWithTag:kSMBEditorPasswordStateTag];
    NSButton *forgetButton = (NSButton *)[[window contentView] viewWithTag:kSMBEditorForgetPasswordTag];
    NSString *server = [self trimmedString:[serverField stringValue]];
    NSString *user = [self trimmedString:[userField stringValue]];
    NSString *domain = [self trimmedString:[domainField stringValue]];
    BOOL validIdentity = ([server length] > 0 &&
                          [user length] > 0 &&
                          [self isValidServerValue:server]);
    BOOL hasSavedPassword = NO;

    if (validIdentity) {
        hasSavedPassword = [self.keychainStore hasPasswordForServer:server user:user domain:domain];
    }

    [forgetButton setEnabled:hasSavedPassword];
    if (hasSavedPassword) {
        [stateLabel setStringValue:@"Password saved in Keychain"];
    } else {
        [stateLabel setStringValue:@""];
    }
}

- (BOOL)validateEditorWindow:(NSWindow *)window
{
    NSTextField *serverField = (NSTextField *)[[window contentView] viewWithTag:kSMBEditorServerTag];
    NSTextField *shareField = (NSTextField *)[[window contentView] viewWithTag:kSMBEditorShareTag];
    NSTextField *errorLabel = (NSTextField *)[[window contentView] viewWithTag:kSMBEditorErrorTag];
    BOOL serverMissing = ([[self trimmedString:[serverField stringValue]] length] == 0);
    BOOL shareMissing = ([[self trimmedString:[shareField stringValue]] length] == 0);
    BOOL serverInvalid = NO;

    if (!serverMissing) {
        serverInvalid = ![self isValidServerValue:[self trimmedString:[serverField stringValue]]];
    }

    [self setEditorField:serverField invalid:(serverMissing || serverInvalid)];
    [self setEditorField:shareField invalid:shareMissing];

    if (!serverMissing && !shareMissing && !serverInvalid) {
        [errorLabel setStringValue:@""];
        return YES;
    }

    if (serverMissing && shareMissing) {
        [errorLabel setStringValue:@"Please fill in Server and Share."];
    } else if (serverInvalid) {
        [errorLabel setStringValue:@"Server must be a valid hostname or IP address."];
    } else if (serverMissing) {
        [errorLabel setStringValue:@"Please fill in Server."];
    } else {
        [errorLabel setStringValue:@"Please fill in Share."];
    }

    if (serverMissing || serverInvalid) {
        [window makeFirstResponder:serverField];
    } else {
        [window makeFirstResponder:shareField];
    }

    return NO;
}

- (void)setEditorField:(NSTextField *)field invalid:(BOOL)invalid
{
    [field setDrawsBackground:YES];
    [field setBackgroundColor:(invalid
                               ? [NSColor colorWithCalibratedRed:1.0 green:0.90 blue:0.90 alpha:1.0]
                               : [NSColor whiteColor])];
}

- (BOOL)isValidServerValue:(NSString *)value
{
    struct in_addr ipv4;
    struct in6_addr ipv6;
    NSArray *labels = nil;
    BOOL numericDotsOnly = NO;
    BOOL hasColon = NO;

    if ([value length] == 0 || [value length] > 253) {
        return NO;
    }
    if (inet_pton(AF_INET, [value UTF8String], &ipv4) == 1 ||
        inet_pton(AF_INET6, [value UTF8String], &ipv6) == 1) {
        return YES;
    }

    hasColon = ([value rangeOfString:@":"].location != NSNotFound);
    if (hasColon) {
        return NO;
    }

    numericDotsOnly = [self smb_stringContainsOnlyDigitsAndDots:value];
    if (numericDotsOnly) {
        return NO;
    }

    if ([value hasPrefix:@"."] || [value hasSuffix:@"."]) {
        return NO;
    }

    labels = [value componentsSeparatedByString:@"."];
    if ([labels count] == 0) {
        return NO;
    }

    for (NSString *label in labels) {
        NSUInteger i = 0;
        unichar c = 0;

        if ([label length] == 0 || [label length] > 63) {
            return NO;
        }
        if ([label hasPrefix:@"-"] || [label hasSuffix:@"-"]) {
            return NO;
        }

        for (i = 0; i < [label length]; i++) {
            c = [label characterAtIndex:i];
            if (!((c >= 'a' && c <= 'z') ||
                  (c >= 'A' && c <= 'Z') ||
                  (c >= '0' && c <= '9') ||
                  c == '-')) {
                return NO;
            }
        }
    }

    return YES;
}

- (BOOL)smb_stringIsNumeric:(NSString *)value
{
    NSUInteger i = 0;
    unichar c = 0;

    if ([value length] == 0) {
        return NO;
    }

    for (i = 0; i < [value length]; i++) {
        c = [value characterAtIndex:i];
        if (!(c >= '0' && c <= '9')) {
            return NO;
        }
    }

    return YES;
}

- (BOOL)smb_stringContainsOnlyDigitsAndDots:(NSString *)value
{
    NSUInteger i = 0;
    unichar c = 0;

    if ([value length] == 0) {
        return NO;
    }

    for (i = 0; i < [value length]; i++) {
        c = [value characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || c == '.')) {
            return NO;
        }
    }

    return YES;
}

- (NSString *)editorValueForTag:(NSInteger)tag inWindow:(NSWindow *)window
{
    NSTextField *field = (NSTextField *)[[window contentView] viewWithTag:tag];
    return [self trimmedString:[field stringValue]];
}

- (BOOL)chooseShareFromArray:(NSArray *)shares intoField:(NSTextField *)shareField nameField:(NSTextField *)nameField
{
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0.0, 0.0, 280.0, 26.0) pullsDown:NO];
    NSString *currentShare = [self trimmedString:[shareField stringValue]];
    NSString *currentName = [self trimmedString:[nameField stringValue]];
    NSString *selectedShare = nil;

    [popup addItemsWithTitles:shares];

    if ([currentShare length] > 0 && [shares containsObject:currentShare]) {
        [popup selectItemWithTitle:currentShare];
    }

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Choose Share"];
    [alert setInformativeText:@"Select a share to use for this connection."];
    [alert setAccessoryView:popup];
    [alert addButtonWithTitle:@"Use Share"];
    [alert addButtonWithTitle:@"Cancel"];

    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return NO;
    }

    selectedShare = [[popup selectedItem] title];
    [shareField setStringValue:selectedShare ?: @""];
    [shareField setNeedsDisplay:YES];

    if ([currentName length] == 0 || ([currentShare length] > 0 && [currentName isEqualToString:currentShare])) {
        [nameField setStringValue:selectedShare ?: @""];
        [nameField setNeedsDisplay:YES];
    }

    return YES;
}

- (void)chooseShareFromArray:(NSArray *)shares forBookmarkAtRow:(NSInteger)row
{
    if (row < 0 || row >= (NSInteger)[self.bookmarks count]) {
        return;
    }

    SMBConnection *bookmark = [self.bookmarks objectAtIndex:(NSUInteger)row];
    NSTextField *shareField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    NSTextField *nameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    SMBConnection *updated = nil;

    [shareField setStringValue:bookmark.share ?: @""];
    [nameField setStringValue:bookmark.name ?: @""];

    if (![self chooseShareFromArray:shares intoField:shareField nameField:nameField]) {
        [self setStatus:@"Share selection cancelled."];
        return;
    }

    updated = [[self.bookmarks objectAtIndex:(NSUInteger)row] copy];
    updated.share = [self trimmedString:[shareField stringValue]];
    updated.name = [self trimmedString:[nameField stringValue]];
    [self.bookmarks replaceObjectAtIndex:(NSUInteger)row withObject:updated];
    [self persistBookmarks];
    [self reloadBookmarkList];
    [self setStatus:[NSString stringWithFormat:@"Selected share '%@'.", [shareField stringValue]]];
}

- (void)showTextPanelWithTitle:(NSString *)title text:(NSString *)text
{
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 420.0, 220.0)];
    [scrollView setBorderType:NSBezelBorder];
    [scrollView setHasVerticalScroller:YES];

    NSTextView *textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 420.0, 220.0)];
    [textView setEditable:NO];
    [textView setString:text ?: @""];
    [textView setFont:[NSFont fontWithName:@"Menlo" size:11.0] ?: [NSFont userFixedPitchFontOfSize:11.0]];
    [scrollView setDocumentView:textView];

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:title ?: @"Details"];
    [alert setAccessoryView:scrollView];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (NSTextView *)aboutLinkViewWithFrame:(NSRect)frame urlString:(NSString *)urlString
{
    NSTextView *textView = [[NSTextView alloc] initWithFrame:frame];
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:urlString ?: @""];
    NSRange range = NSMakeRange(0, [attr length]);

    [attr addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:12.0] range:range];
    [attr addAttribute:NSForegroundColorAttributeName value:[NSColor blueColor] range:range];
    [attr addAttribute:NSUnderlineStyleAttributeName value:[NSNumber numberWithInt:NSUnderlineStyleSingle] range:range];
    [attr addAttribute:NSLinkAttributeName value:(urlString ?: @"") range:range];

    [textView setEditable:NO];
    [textView setSelectable:YES];
    [textView setRichText:YES];
    [textView setDrawsBackground:NO];
    [textView setAlignment:NSCenterTextAlignment];
    [textView setHorizontallyResizable:NO];
    [textView setVerticallyResizable:NO];
    [[textView textContainer] setContainerSize:NSMakeSize(frame.size.width, frame.size.height)];
    [[textView textContainer] setWidthTracksTextView:YES];
    [[textView layoutManager] ensureLayoutForTextContainer:[textView textContainer]];
    [[textView textStorage] setAttributedString:attr];
    return textView;
}

- (NSDictionary *)connectionExchangeDocumentFromData:(NSData *)data error:(NSError **)error
{
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    NSDictionary *document = nil;
    id format = nil;
    id version = nil;
    id connections = nil;

    if (![json isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"SMB2FUSEGUI"
                                         code:1001
                                     userInfo:[NSDictionary dictionaryWithObject:@"The file must contain a JSON object at the top level."
                                                                          forKey:NSLocalizedDescriptionKey]];
        }
        return nil;
    }

    document = (NSDictionary *)json;
    format = [document objectForKey:@"format"];
    version = [document objectForKey:@"version"];
    connections = [document objectForKey:@"connections"];

    if (![format isKindOfClass:[NSString class]] || ![(NSString *)format isEqualToString:kSMBConnectionExchangeFormat]) {
        if (error) {
            *error = [NSError errorWithDomain:@"SMB2FUSEGUI"
                                         code:1002
                                     userInfo:[NSDictionary dictionaryWithObject:@"This file does not look like an SMB2 FUSE connections export."
                                                                          forKey:NSLocalizedDescriptionKey]];
        }
        return nil;
    }
    if (![version respondsToSelector:@selector(integerValue)] || [version integerValue] != kSMBConnectionExchangeVersion) {
        if (error) {
            *error = [NSError errorWithDomain:@"SMB2FUSEGUI"
                                         code:1003
                                     userInfo:[NSDictionary dictionaryWithObject:@"This connections export version is not supported."
                                                                          forKey:NSLocalizedDescriptionKey]];
        }
        return nil;
    }
    if (![connections isKindOfClass:[NSArray class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"SMB2FUSEGUI"
                                         code:1004
                                     userInfo:[NSDictionary dictionaryWithObject:@"The file does not contain a valid connections list."
                                                                          forKey:NSLocalizedDescriptionKey]];
        }
        return nil;
    }

    return document;
}

- (SMBConnection *)normalizedImportedBookmarkFromDictionary:(NSDictionary *)dictionary issues:(NSMutableArray *)issues
{
    SMBConnection *bookmark = [[SMBConnection alloc] init];
    NSString *name = nil;
    NSString *server = nil;
    NSString *share = nil;
    NSString *user = nil;
    NSString *domain = nil;
    NSString *label = nil;

    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        [issues addObject:@"Skipped one entry because it was not a JSON object."];
        return nil;
    }

    name = [self trimmedStringFromObject:[dictionary objectForKey:@"name"]];
    server = [self trimmedStringFromObject:[dictionary objectForKey:@"server"]];
    share = [self trimmedStringFromObject:[dictionary objectForKey:@"share"]];
    user = [self trimmedStringFromObject:[dictionary objectForKey:@"user"]];
    domain = [self trimmedStringFromObject:[dictionary objectForKey:@"domain"]];
    label = [name length] > 0 ? name : ([share length] > 0 ? share : @"Unnamed connection");

    if ([server length] == 0 || [share length] == 0) {
        [issues addObject:[NSString stringWithFormat:@"Skipped '%@' because Server and Share are required.", label]];
        return nil;
    }
    if (![self isValidServerValue:server]) {
        [issues addObject:[NSString stringWithFormat:@"Skipped '%@' because '%@' is not a valid server.", label, server]];
        return nil;
    }

    bookmark.uuid = [SMBConnection generatedUUID];
    bookmark.name = name;
    bookmark.server = server;
    bookmark.share = share;
    bookmark.user = user;
    bookmark.domain = domain;
    return bookmark;
}

- (NSInteger)importChoiceForConnectionNames:(NSArray *)names
{
    NSAlert *alert = [[NSAlert alloc] init];
    NSString *summary = nil;

    if ([names count] == 2) {
        summary = [NSString stringWithFormat:@"This file contains %lu connections. You can import both, or choose just one.",
                   (unsigned long)[names count]];
    } else {
        summary = [NSString stringWithFormat:@"This file contains %lu connections. You can import all of them, or choose a single one.",
                   (unsigned long)[names count]];
    }

    [alert setMessageText:@"Import Connections"];
    [alert setInformativeText:summary];
    [alert addButtonWithTitle:@"Import All"];
    [alert addButtonWithTitle:@"Choose One"];
    [alert addButtonWithTitle:@"Cancel"];
    return [alert runModal];
}

- (SMBConnection *)chooseImportedConnectionFromArray:(NSArray *)connections
{
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0.0, 0.0, 320.0, 26.0) pullsDown:NO];
    NSAlert *alert = [[NSAlert alloc] init];
    NSUInteger i = 0;

    for (i = 0; i < [connections count]; i++) {
        SMBConnection *bookmark = [connections objectAtIndex:i];
        NSString *title = [self bookmarkDisplayName:bookmark];
        NSString *server = bookmark.server ?: @"";
        if ([server length] > 0) {
            title = [NSString stringWithFormat:@"%@ (%@)", title, server];
        }
        [popup addItemWithTitle:title];
    }

    [alert setMessageText:@"Choose Connection"];
    [alert setInformativeText:@"Select which connection you want to import from this file."];
    [alert setAccessoryView:popup];
    [alert addButtonWithTitle:@"Import"];
    [alert addButtonWithTitle:@"Cancel"];

    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return nil;
    }

    if ([popup indexOfSelectedItem] < 0 || [popup indexOfSelectedItem] >= (NSInteger)[connections count]) {
        return nil;
    }

    return [connections objectAtIndex:(NSUInteger)[popup indexOfSelectedItem]];
}

- (void)exportBookmarks:(NSArray *)bookmarks defaultName:(NSString *)defaultName statusLabel:(NSString *)statusLabel
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    NSDictionary *document = [self exportDocumentForBookmarks:bookmarks];
    NSData *data = nil;
    NSError *error = nil;
    NSString *path = nil;

    [panel setAllowedFileTypes:[NSArray arrayWithObject:@"json"]];
    [panel setCanCreateDirectories:YES];
    [panel setNameFieldStringValue:defaultName ?: @"Connections.json"];

    if ([panel runModal] != NSFileHandlingPanelOKButton) {
        [self setStatus:@"Export cancelled."];
        return;
    }

    data = [NSJSONSerialization dataWithJSONObject:document options:NSJSONWritingPrettyPrinted error:&error];
    if (!data) {
        [self showTextPanelWithTitle:@"Export Failed"
                                text:[NSString stringWithFormat:@"Could not prepare the export data.\n\n%@",
                                      [error localizedDescription] ?: @"Unknown error."]];
        [self setStatus:@"Export failed."];
        return;
    }

    path = [[[panel URL] path] copy];
    if ([[path pathExtension] length] == 0) {
        path = [path stringByAppendingPathExtension:@"json"];
    }

    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        [self showTextPanelWithTitle:@"Export Failed"
                                text:[NSString stringWithFormat:@"Could not write the export file.\n\n%@",
                                      [error localizedDescription] ?: @"Unknown error."]];
        [self setStatus:@"Export failed."];
        return;
    }

    (void)statusLabel;
    [self setStatus:[NSString stringWithFormat:@"Exported %lu connection%@.",
                     (unsigned long)[bookmarks count],
                     [bookmarks count] == 1 ? @"" : @"s"]];
}

- (NSDictionary *)exportDocumentForBookmarks:(NSArray *)bookmarks
{
    NSMutableArray *connections = [NSMutableArray array];

    for (SMBConnection *bookmark in bookmarks) {
        [connections addObject:[self exportRepresentationForBookmark:bookmark]];
    }

    return [NSDictionary dictionaryWithObjectsAndKeys:
            kSMBConnectionExchangeFormat, @"format",
            [NSNumber numberWithInteger:kSMBConnectionExchangeVersion], @"version",
            connections, @"connections",
            nil];
}

- (NSDictionary *)exportRepresentationForBookmark:(SMBConnection *)bookmark
{
    return [bookmark exportRepresentation];
}

- (NSDictionary *)preparedPasswordDecisionForServer:(NSString *)server
                                               user:(NSString *)user
                                             domain:(NSString *)domain
                                              title:(NSString *)title
                                            message:(NSString *)message
{
    BOOL foundInKeychain = NO;
    NSString *savedPassword = nil;
    NSPanel *panel = nil;
    NSView *content = nil;
    NSTextField *messageLabel = nil;
    NSSecureTextField *passwordField = nil;
    NSButton *rememberCheckbox = nil;
    NSButton *cancelButton = nil;
    NSButton *continueButton = nil;
    NSInteger response = NSAlertSecondButtonReturn;

    if ([user length] == 0) {
        return [NSDictionary dictionaryWithObjectsAndKeys:
                @"", @"password",
                [NSNumber numberWithBool:NO], @"remember",
                nil];
    }

    savedPassword = [self.keychainStore passwordForServer:server
                                                     user:user
                                                   domain:domain
                                                    found:&foundInKeychain];
    if (foundInKeychain) {
        return [NSDictionary dictionaryWithObjectsAndKeys:
                savedPassword ?: @"", @"password",
                [NSNumber numberWithBool:NO], @"remember",
                nil];
    }

    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 360.0, 158.0)
                                       styleMask:(NSTitledWindowMask | NSClosableWindowMask)
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
    content = [panel contentView];
    [panel setTitle:title ?: @"Password Required"];
    [panel center];

    messageLabel = [self labelWithString:message ?: @"Enter the password."
                                   frame:NSMakeRect(18.0, 108.0, 324.0, 36.0)
                                    bold:NO];
    [messageLabel setFont:[NSFont systemFontOfSize:12.0]];
    [messageLabel setAlignment:NSLeftTextAlignment];
    [[messageLabel cell] setWraps:YES];
    [[messageLabel cell] setLineBreakMode:NSLineBreakByWordWrapping];
    [content addSubview:messageLabel];

    passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(18.0, 76.0, 324.0, 24.0)];
    [content addSubview:passwordField];

    rememberCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(18.0, 46.0, 220.0, 18.0)];
    [rememberCheckbox setButtonType:NSSwitchButton];
    [rememberCheckbox setTitle:@"Remember password in Keychain"];
    [rememberCheckbox setState:NSOffState];
    [content addSubview:rememberCheckbox];

    cancelButton = [self buttonWithTitle:@"Cancel"
                                   frame:NSMakeRect(186.0, 10.0, 78.0, 28.0)
                                  action:@selector(cancelEditorPanel:)];
    continueButton = [self buttonWithTitle:@"Continue"
                                     frame:NSMakeRect(270.0, 10.0, 78.0, 28.0)
                                    action:@selector(confirmSimplePanel:)];
    [continueButton setKeyEquivalent:@"\r"];
    [content addSubview:cancelButton];
    [content addSubview:continueButton];

    [panel setInitialFirstResponder:passwordField];
    response = [NSApp runModalForWindow:panel];
    if (response != NSAlertFirstButtonReturn) {
        return nil;
    }

    return [NSDictionary dictionaryWithObjectsAndKeys:
            [passwordField stringValue] ?: @"", @"password",
            [NSNumber numberWithBool:([rememberCheckbox state] == NSOnState)], @"remember",
            nil];
}

- (NSArray *)parseShareNamesFromOutput:(NSString *)output
{
    NSMutableArray *shares = [NSMutableArray array];
    NSArray *lines = [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSArray *columns = [self columnsFromShareLine:line];
        NSString *type = nil;

        if ([trimmed length] == 0 ||
            [trimmed hasPrefix:@"Name"] ||
            [trimmed hasPrefix:@"----"] ||
            [trimmed hasPrefix:@"Info:"]) {
            continue;
        }
        if ([columns count] < 2) {
            continue;
        }

        type = [columns objectAtIndex:1];
        if (![type isEqualToString:@"disk"]) {
            continue;
        }

        [shares addObject:[columns objectAtIndex:0]];
    }

    return shares;
}

- (NSArray *)columnsFromShareLine:(NSString *)line
{
    NSMutableArray *columns = [NSMutableArray array];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\s{2,}"
                                                                           options:0
                                                                             error:NULL];
    __block NSUInteger start = 0;

    [regex enumerateMatchesInString:line
                            options:0
                              range:NSMakeRange(0, [line length])
                         usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
        (void)flags;
        (void)stop;

        NSRange range = [result range];
        NSString *piece = [[line substringWithRange:NSMakeRange(start, range.location - start)]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([piece length] > 0 || [columns count] > 0) {
            [columns addObject:piece];
        }
        start = NSMaxRange(range);
    }];

    if (start < [line length]) {
        NSString *tail = [[line substringFromIndex:start] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([tail length] > 0 || [columns count] > 0) {
            [columns addObject:tail];
        }
    }

    return columns;
}

- (void)loadBookmarks
{
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kSMBBookmarkDefaultsKey];
    if (!stored) {
        return;
    }

    for (NSDictionary *bookmark in stored) {
        [self.bookmarks addObject:[SMBConnection connectionFromDictionary:bookmark]];
    }

    [self persistBookmarks];
}

- (void)persistBookmarks
{
    NSMutableArray *stored = [NSMutableArray array];

    for (SMBConnection *bookmark in self.bookmarks) {
        [stored addObject:[bookmark dictionaryRepresentation]];
    }

    [[NSUserDefaults standardUserDefaults] setObject:stored forKey:kSMBBookmarkDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)reloadBookmarkList
{
    [self syncBookmarkColumnWidth];
    [self.bookmarksTable reloadData];
    [self refreshButtons];
    [self refreshCount];
    [self rebuildBookmarksMenu];
    [self updateEmptyState];
}

- (void)requestMountedStateRefresh
{
    if (self.refreshInProgress) {
        self.refreshPending = YES;
        return;
    }

    self.refreshInProgress = YES;
    [self.taskRunner runCommandAtPath:@"/sbin/mount"
                            arguments:nil
                          stdinString:nil
                           completion:^(int status, NSString *output) {
        NSArray *entries = nil;

        self.refreshInProgress = NO;
        if (status == 0) {
            entries = [self mountedEntriesFromOutput:output];
            [self applyMountedEntries:entries];
            [self reloadBookmarkList];
        }

        if (self.refreshPending) {
            self.refreshPending = NO;
            [self requestMountedStateRefresh];
        }
    }];
}

- (void)refreshButtons
{
    BOOL hasSelection = ([self selectedBookmarkRow] >= 0);
    SMBConnection *bookmark = [self selectedBookmark];
    BOOL isMounted = (bookmark != nil && [self isBookmarkMounted:bookmark]);
    (void)hasSelection;
    (void)isMounted;
}

- (void)rebuildBookmarksMenu
{
    NSInteger i = 0;

    [self.bookmarksMenu removeAllItems];
    if ([self.bookmarks count] == 0) {
        NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:@"No Connections" action:NULL keyEquivalent:@""];
        [empty setEnabled:NO];
        [self.bookmarksMenu addItem:empty];
        return;
    }

    for (i = 0; i < (NSInteger)[self.bookmarks count]; i++) {
        SMBConnection *bookmark = [self.bookmarks objectAtIndex:(NSUInteger)i];
        NSString *uuid = bookmark.uuid;
        NSString *title = [self bookmarkMenuTitleForBookmark:bookmark];
        NSMenuItem *item = [self menuItemWithTitle:title
                                            action:@selector(selectBookmarkFromMenuItem:)
                                       keyEquivalent:@""
                                       keyModifiers:0];

        [item setRepresentedObject:uuid ?: @""];
        if (i == [self selectedBookmarkRow]) {
            [item setState:NSOnState];
        }
        [self.bookmarksMenu addItem:item];
    }
}

- (void)refreshCount
{
    NSUInteger count = [self.bookmarks count];
    [self.countField setStringValue:[NSString stringWithFormat:@"%lu connection%@",
                                     (unsigned long)count,
                                     count == 1 ? @"" : @"s"]];
}

- (void)updateEmptyState
{
    BOOL isEmpty = ([self.bookmarks count] == 0);
    [self.emptyStateView setHidden:!isEmpty];
    [self.bookmarksTable setHidden:isEmpty];
    if (isEmpty) {
        [self setStatus:@"Create a new connection to get started."];
    }
}

- (void)setControlsEnabled:(BOOL)enabled
{
    self.taskRunning = !enabled;
    [self refreshButtons];
}

- (SMBConnection *)selectedBookmark
{
    NSInteger row = [self selectedBookmarkRow];
    if (row < 0 || row >= (NSInteger)[self.bookmarks count]) {
        return nil;
    }
    return [self.bookmarks objectAtIndex:(NSUInteger)row];
}

- (NSInteger)selectedBookmarkRow
{
    NSInteger row = [self.bookmarksTable selectedRow];
    NSInteger contextualRow = -1;

    if ([self.bookmarksTable isKindOfClass:[SMBBookmarkTableView class]]) {
        contextualRow = [(SMBBookmarkTableView *)self.bookmarksTable contextualRow];
    }

    if (row < 0 || row >= (NSInteger)[self.bookmarks count]) {
        if (contextualRow < 0 || contextualRow >= (NSInteger)[self.bookmarks count]) {
            return -1;
        }
        return contextualRow;
    }
    return row;
}

- (NSString *)bookmarkDisplayName:(SMBConnection *)bookmark
{
    return [bookmark displayName];
}

- (NSString *)bookmarkMenuTitleForBookmark:(SMBConnection *)bookmark
{
    return [bookmark menuTitleWithMounted:[self isBookmarkMounted:bookmark]];
}

- (NSInteger)rowForBookmarkUUID:(NSString *)uuid
{
    NSInteger i = 0;

    if ([uuid length] == 0) {
        return -1;
    }

    for (i = 0; i < (NSInteger)[self.bookmarks count]; i++) {
        SMBConnection *bookmark = [self.bookmarks objectAtIndex:(NSUInteger)i];
        if ([bookmark.uuid isEqualToString:uuid]) {
            return i;
        }
    }

    return -1;
}

- (NSString *)mountedPathForBookmark:(SMBConnection *)bookmark
{
    return bookmark.mountedPath ?: @"";
}

- (BOOL)isBookmarkMounted:(SMBConnection *)bookmark
{
    return [[self mountedPathForBookmark:bookmark] length] > 0;
}

- (void)openMountedBookmarkInFinder:(SMBConnection *)bookmark
{
    NSString *mountpoint = [self mountedPathForBookmark:bookmark];

    if ([mountpoint length] == 0) {
        [self setStatus:@"This connection is not currently connected."];
        return;
    }

    if ([[NSFileManager defaultManager] fileExistsAtPath:mountpoint]) {
        if ([[NSWorkspace sharedWorkspace] openFile:mountpoint]) {
            [self setStatus:[NSString stringWithFormat:@"Opened %@ in Finder.", [self bookmarkDisplayName:bookmark]]];
        } else {
            [self setStatus:@"Finder could not open the mounted folder."];
        }
    } else {
        bookmark.mountedPath = nil;
        [self reloadBookmarkList];
        [self setStatus:@"The saved mount path no longer exists."];
    }
}

- (NSString *)applicationDisplayName
{
    NSString *name = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleDisplayName"];
    if ([name length] == 0) {
        name = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleName"];
    }
    if ([name length] == 0) {
        name = @"SMB2 FUSE";
    }
    return name;
}

- (NSString *)mountpointFromOutput:(NSString *)output
{
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"Using '([^']+)' as mountpoint\\."
                                                                           options:0
                                                                             error:NULL];
    NSTextCheckingResult *match = [regex firstMatchInString:output
                                                    options:0
                                                      range:NSMakeRange(0, [output length])];
    if (!match || [match numberOfRanges] < 2) {
        return @"";
    }
    return [output substringWithRange:[match rangeAtIndex:1]];
}

- (NSString *)bestGuessMountpointForBookmark:(SMBConnection *)bookmark
{
    NSArray *candidates = [self mountpointCandidatesForBookmark:bookmark];
    NSFileManager *fm = [NSFileManager defaultManager];

    if ([bookmark.share length] == 0) {
        return @"";
    }

    for (NSString *candidate in candidates) {
        if ([fm fileExistsAtPath:candidate]) {
            return candidate;
        }
    }

    return [@"/Volumes" stringByAppendingPathComponent:bookmark.share];
}

- (NSArray *)mountpointCandidatesForBookmark:(SMBConnection *)bookmark
{
    return [bookmark mountpointCandidates];
}

- (NSArray *)mountedEntriesFromOutput:(NSString *)output
{
    NSMutableArray *entries = [NSMutableArray array];
    NSArray *lines = [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^(.*?) on (.+?) \\("
                                                                           options:0
                                                                             error:NULL];

    for (NSString *line in lines) {
        NSTextCheckingResult *match = [regex firstMatchInString:line
                                                        options:0
                                                          range:NSMakeRange(0, [line length])];
        NSString *source = nil;
        NSString *mountpoint = nil;

        if (!match || [match numberOfRanges] < 3) {
            continue;
        }
        source = [self normalizedMountSource:[line substringWithRange:[match rangeAtIndex:1]]];
        mountpoint = [[line substringWithRange:[match rangeAtIndex:2]]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([mountpoint length] == 0) {
            continue;
        }
        [entries addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                            source ?: @"", @"source",
                            mountpoint, @"mountpoint",
                            nil]];
    }

    return entries;
}

- (void)applyMountedEntries:(NSArray *)entries
{
    NSMutableSet *mountedPaths = [NSMutableSet set];
    NSMutableDictionary *pathsBySource = [NSMutableDictionary dictionary];
    NSMutableDictionary *candidateOwners = [NSMutableDictionary dictionary];

    for (NSDictionary *entry in entries) {
        NSString *mountpoint = [entry objectForKey:@"mountpoint"] ?: @"";
        NSString *source = [[entry objectForKey:@"source"] ?: @"" lowercaseString];
        NSMutableArray *mountpoints = nil;

        if ([mountpoint length] == 0) {
            continue;
        }

        [mountedPaths addObject:mountpoint];
        if ([source length] == 0) {
            continue;
        }

        mountpoints = [pathsBySource objectForKey:source];
        if (!mountpoints) {
            mountpoints = [NSMutableArray array];
            [pathsBySource setObject:mountpoints forKey:source];
        }
        [mountpoints addObject:mountpoint];
    }

    for (SMBConnection *bookmark in self.bookmarks) {
        for (NSString *candidate in [bookmark mountpointCandidates]) {
            NSMutableArray *owners = [candidateOwners objectForKey:candidate];
            if (!owners) {
                owners = [NSMutableArray array];
                [candidateOwners setObject:owners forKey:candidate];
            }
            [owners addObject:bookmark.uuid ?: @""];
        }
    }

    for (SMBConnection *bookmark in self.bookmarks) {
        NSString *resolvedPath = nil;
        NSArray *sourceMatches = nil;

        if ([bookmark.mountedPath length] > 0 && [mountedPaths containsObject:bookmark.mountedPath]) {
            continue;
        }

        sourceMatches = [pathsBySource objectForKey:[bookmark expectedFSName]];
        if ([sourceMatches count] == 1) {
            resolvedPath = [sourceMatches objectAtIndex:0];
        } else if ([sourceMatches count] > 1) {
            resolvedPath = nil;
        } else {
            NSMutableArray *candidateMatches = [NSMutableArray array];
            for (NSString *candidate in [bookmark mountpointCandidates]) {
                NSArray *owners = [candidateOwners objectForKey:candidate];
                if ([mountedPaths containsObject:candidate] && [owners count] == 1) {
                    [candidateMatches addObject:candidate];
                }
            }
            if ([candidateMatches count] == 1) {
                resolvedPath = [candidateMatches objectAtIndex:0];
            }
        }

        bookmark.mountedPath = [resolvedPath length] > 0 ? resolvedPath : nil;
    }
}

- (NSString *)normalizedMountSource:(NSString *)source
{
    NSString *trimmed = [[source ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSRange fsnameRange = [trimmed rangeOfString:@"//"];

    if (fsnameRange.location != NSNotFound) {
        return [trimmed substringFromIndex:fsnameRange.location];
    }
    return trimmed;
}

- (NSString *)trimmedString:(NSString *)string
{
    return [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSString *)trimmedStringFromObject:(id)object
{
    if (![object isKindOfClass:[NSString class]]) {
        return @"";
    }
    return [self trimmedString:(NSString *)object];
}

- (NSString *)safeFilenameForConnectionName:(NSString *)name
{
    NSMutableString *clean = [NSMutableString string];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ "];
    NSUInteger i = 0;

    if ([name length] == 0) {
        return @"Connection";
    }

    for (i = 0; i < [name length]; i++) {
        unichar c = [name characterAtIndex:i];
        if ([allowed characterIsMember:c]) {
            [clean appendFormat:@"%C", c];
        } else {
            [clean appendString:@"-"];
        }
    }

    while ([clean hasPrefix:@" "]) {
        [clean deleteCharactersInRange:NSMakeRange(0, 1)];
    }
    while ([clean hasSuffix:@" "]) {
        [clean deleteCharactersInRange:NSMakeRange([clean length] - 1, 1)];
    }

    if ([clean length] == 0) {
        return @"Connection";
    }

    return clean;
}

- (void)setStatus:(NSString *)status
{
    [self.statusField setStringValue:status ?: @""];
}

- (NSString *)smb2fsExecutablePath
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *resourcePath = [[NSBundle mainBundle] pathForResource:@"smb2fs" ofType:nil];
    if ([resourcePath length] > 0 && [fm isExecutableFileAtPath:resourcePath]) {
        return resourcePath;
    }

    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *repoPath = [[[[bundlePath stringByDeletingLastPathComponent]
                            stringByDeletingLastPathComponent]
                           stringByAppendingPathComponent:@"../cli/smb2fs"] stringByStandardizingPath];
    if ([fm isExecutableFileAtPath:repoPath]) {
        return repoPath;
    }

    if ([fm isExecutableFileAtPath:@"/usr/local/bin/smb2fs"]) {
        return @"/usr/local/bin/smb2fs";
    }

    return @"";
}

- (void)appendOptionalFlag:(NSString *)flag value:(NSString *)value toArguments:(NSMutableArray *)arguments
{
    if ([value length] > 0) {
        [arguments addObject:flag];
        [arguments addObject:value];
    }
}

- (NSMutableArray *)mountArgumentsForConnection:(SMBConnection *)connection
{
    NSMutableArray *arguments = [NSMutableArray arrayWithObjects:
                                 @"--server", connection.server ?: @"",
                                 @"--share", connection.share ?: @"",
                                 nil];

    [self appendOptionalFlag:@"--user" value:connection.user toArguments:arguments];
    [self appendOptionalFlag:@"--domain" value:connection.domain toArguments:arguments];
    if ([connection.user length] > 0) {
        [arguments addObject:@"--passfd"];
        [arguments addObject:@"0"];
    }
    return arguments;
}

- (NSMutableArray *)listSharesArgumentsForConnection:(SMBConnection *)connection
{
    return [self listSharesArgumentsForServer:connection.server
                                         user:connection.user
                                       domain:connection.domain];
}

- (NSMutableArray *)listSharesArgumentsForServer:(NSString *)server
                                            user:(NSString *)user
                                          domain:(NSString *)domain
{
    NSMutableArray *arguments = [NSMutableArray arrayWithObjects:@"--list-shares", @"--server", server ?: @"", nil];

    [self appendOptionalFlag:@"--user" value:user toArguments:arguments];
    [self appendOptionalFlag:@"--domain" value:domain toArguments:arguments];
    if ([user length] > 0) {
        [arguments addObject:@"--passfd"];
        [arguments addObject:@"0"];
    }
    return arguments;
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
    SEL action = [menuItem action];
    SMBConnection *bookmark = [self selectedBookmark];
    BOOL hasSelection = (bookmark != nil);
    BOOL isMounted = (hasSelection && [self isBookmarkMounted:bookmark]);
    NSString *uuid = nil;

    if (action == @selector(addBookmark:)) {
        return !self.taskRunning;
    }
    if (action == @selector(importConnections:)) {
        return !self.taskRunning;
    }
    if (action == @selector(selectBookmarkFromMenuItem:)) {
        uuid = [menuItem representedObject];
        return ([uuid length] > 0 && [self rowForBookmarkUUID:uuid] >= 0);
    }
    if (action == @selector(editBookmark:) ||
        action == @selector(removeBookmark:) ||
        action == @selector(duplicateSelectedBookmark:) ||
        action == @selector(listShares:)) {
        return hasSelection && !self.taskRunning;
    }
    if (action == @selector(exportSelectedBookmark:)) {
        return hasSelection && !self.taskRunning;
    }
    if (action == @selector(exportAllBookmarks:)) {
        return ([self.bookmarks count] > 0) && !self.taskRunning;
    }
    if (action == @selector(connectSelectedBookmark:)) {
        return hasSelection && !isMounted && !self.taskRunning;
    }
    if (action == @selector(disconnectSelectedBookmark:) ||
        action == @selector(openSelectedBookmarkInFinder:) ||
        action == @selector(revealSelectedMountPoint:) ||
        action == @selector(activateSelectedBookmark:)) {
        return hasSelection && isMounted && !self.taskRunning;
    }
    if (action == @selector(closeWindow:)) {
        return ([self.window isVisible] != NO);
    }
    return YES;
}

@end
