/*
 ===========================================================================
 RAM Terminal - 完美净化版 (修复所有乱码 & 编译错误)
 编译：clang -fobjc-arc -framework Cocoa -lutil -o MyTerminal main.m
 ===========================================================================
 */

#import <Cocoa/Cocoa.h>
#import <util.h>
#import <unistd.h>
#import <termios.h>

#define COLOR_BG [NSColor colorWithCalibratedRed:0.15 green:0.15 blue:0.15 alpha:1.0]
#define COLOR_FG [NSColor colorWithCalibratedRed:0.83 green:0.83 blue:0.83 alpha:1.0]
#define COLOR_SEL [NSColor colorWithCalibratedRed:0.25 green:0.35 blue:0.50 alpha:1.0]

// ==========================================
// 1. Terminal View
// ==========================================
@interface RealTerminalView : NSTextView
@property (assign) int masterFD;
@end

@implementation RealTerminalView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.backgroundColor = COLOR_BG;
        self.textColor = COLOR_FG;
        // 使用等宽字体，视觉效果更像终端
        self.font = [NSFont fontWithName:@"Menlo" size:14] ?: [NSFont userFixedPitchFontOfSize:14];
        
        self.selectable = YES;
        self.editable = NO;
        self.allowsUndo = NO;
        self.richText = NO;
        self.importsGraphics = NO;
        self.drawsBackground = YES;
        
        self.textContainer.widthTracksTextView = YES;
        self.textContainer.containerSize = NSMakeSize(FLT_MAX, FLT_MAX);
        
        self.selectedTextAttributes = @{
            NSBackgroundColorAttributeName: COLOR_SEL,
            NSForegroundColorAttributeName: [NSColor whiteColor]
        };
    }
    return self;
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(paste:)) {
        return [[[NSPasteboard generalPasteboard] types] containsObject:NSPasteboardTypeString];
    }
    if (menuItem.action == @selector(copy:)) {
        return [self selectedRange].length > 0;
    }
    if (menuItem.action == @selector(selectAll:)) {
        return self.string.length > 0;
    }
    return [super validateMenuItem:menuItem];
}

- (void)paste:(id)sender {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *text = [pb stringForType:NSPasteboardTypeString];
    if (text) {
        const char *utf8 = [text UTF8String];
        write(_masterFD, utf8, strlen(utf8));
    }
}

- (void)keyDown:(NSEvent *)event {
    if ([event modifierFlags] & NSEventModifierFlagCommand) {
        [super keyDown:event];
        return;
    }

    NSString *chars = [event characters];
    if (chars.length > 0) {
        const char *utf8 = [chars UTF8String];
        
        if ([chars isEqualToString:@"\r"] || [chars isEqualToString:@"\n"]) {
            char c = '\r'; write(_masterFD, &c, 1);
        }
        else if ([chars isEqualToString:@"\b"] || [event keyCode] == 51) {
            char c = 0x7F; write(_masterFD, &c, 1);
        }
        // 方向键映射 (Standard ANSI sequences)
        else if ([event keyCode] == 126) write(_masterFD, "\033[A", 3); // Up
        else if ([event keyCode] == 125) write(_masterFD, "\033[B", 3); // Down
        else if ([event keyCode] == 124) write(_masterFD, "\033[C", 3); // Right
        else if ([event keyCode] == 123) write(_masterFD, "\033[D", 3); // Left
        else {
            write(_masterFD, utf8, strlen(utf8));
        }
    }
}

@end

// ==========================================
// 2. Main Window Controller
// ==========================================
@interface MainWindowController : NSWindowController
@property (strong) RealTerminalView *terminalView;
@property (assign) int masterFD;
@property (strong) NSFileHandle *fileHandle;
@property (strong) NSRegularExpression *ansiRegex;
@end

@implementation MainWindowController

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 900, 600);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame 
                                                   styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable 
                                                     backing:NSBackingStoreBuffered 
                                                       defer:NO];
    [window center];
    window.title = @"RAM Terminal (Clean Mode)";
    self = [super initWithWindow:window];
    if (self) {
        // -----------------------------------------------------
        // 核心修复: 超强正则过滤
        // 1. CSI: \x1b\[ ... (含 ? 等私有参数) -> 过滤颜色、光标、粘贴模式
        // 2. OSC: \x1b\] ... \x07|\x1b\\       -> 过滤路径设置 (]7;file...)
        // -----------------------------------------------------
        NSString *patternCSI = @"\\x1b\\[[\\?0-9;]*[a-zA-Z]"; 
        NSString *patternOSC = @"\\x1b\\][^\\x07\\x1b]*(\\x07|\\x1b\\\\)";
        NSString *fullPattern = [NSString stringWithFormat:@"(%@)|(%@)", patternCSI, patternOSC];
        
        _ansiRegex = [NSRegularExpression regularExpressionWithPattern:fullPattern options:0 error:nil];
        
        [self setupUI];
        [self setupPTY];
    }
    return self;
}

- (void)setupUI {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:self.window.contentView.bounds];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = YES;
    scroll.backgroundColor = COLOR_BG;

    self.terminalView = [[RealTerminalView alloc] initWithFrame:scroll.bounds];
    self.terminalView.minSize = NSMakeSize(0.0, scroll.bounds.size.height);
    self.terminalView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.terminalView.verticallyResizable = YES;
    self.terminalView.horizontallyResizable = NO;
    self.terminalView.autoresizingMask = NSViewWidthSizable;
    
    scroll.documentView = self.terminalView;
    [self.window.contentView addSubview:scroll];
    [self.window makeFirstResponder:self.terminalView];
}

- (void)setupPTY {
    struct winsize size = { .ws_row = 40, .ws_col = 100 };
    pid_t pid = forkpty(&_masterFD, NULL, NULL, &size);

    if (pid == 0) {
        // 核心修复: 设置 TERM 为 dumb
        // 这样 Zsh 就知道不要发送复杂的 OSC 序列或开启 Bracketed Paste Mode
        setenv("TERM", "dumb", 1);
        setenv("LANG", "en_US.UTF-8", 1);
        
        // 禁止 Zsh 的部分自动纠正和提示，让输出更干净
        setenv("ZSH_AUTOSUGGEST_DISABLE", "true", 1);
        
        char *shell = "/bin/zsh"; 
        // 使用 -f 跳过用户配置（可选，如果你想跳过 .zshrc）
        // char *args[] = {shell, "-f", "-i", NULL}; 
        // execl(shell, shell, "-f", "-i", NULL);
        
        // 正常加载
        execl(shell, shell, "-i", "-l", NULL);
        exit(1);
    }

    self.terminalView.masterFD = _masterFD;
    self.fileHandle = [[NSFileHandle alloc] initWithFileDescriptor:_masterFD closeOnDealloc:YES];

    __weak typeof(self) weakSelf = self;
    self.fileHandle.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        if (data.length > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf appendText:data];
            });
        }
    };
}

- (void)appendText:(NSData *)data {
    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!str) str = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
    if (!str) return;

    // 1. 执行正则清洗
    NSString *cleanStr = [self.ansiRegex stringByReplacingMatchesInString:str 
                                                                  options:0 
                                                                    range:NSMakeRange(0, str.length) 
                                                             withTemplate:@""];
    
    // 2. 清洗回车符 (NSTextView 处理换行不同)
    cleanStr = [cleanStr stringByReplacingOccurrencesOfString:@"\r" withString:@""];

    if (cleanStr.length == 0) return;

    NSTextStorage *ts = self.terminalView.textStorage;
    NSDictionary *attrs = @{
        NSFontAttributeName: self.terminalView.font,
        NSForegroundColorAttributeName: self.terminalView.textColor
    };
    
    // 3. 简易退格处理
    if ([cleanStr containsString:@"\b"]) {
        cleanStr = [cleanStr stringByReplacingOccurrencesOfString:@"\b" withString:@""];
        if (ts.length > 0) [ts deleteCharactersInRange:NSMakeRange(ts.length - 1, 1)];
    }

    NSAttributedString *as = [[NSAttributedString alloc] initWithString:cleanStr attributes:attrs];
    [ts beginEditing];
    [ts appendAttributedString:as];
    if (ts.length > 50000) [ts deleteCharactersInRange:NSMakeRange(0, 10000)];
    [ts endEditing];
    
    [self.terminalView scrollRangeToVisible:NSMakeRange(ts.length, 0)];
}
@end

// ==========================================
// 3. App Delegate
// ==========================================
@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) MainWindowController *mwc;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)a {
    [self createMenuBar];
    self.mwc = [[MainWindowController alloc] init];
    [self.mwc.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)createMenuBar {
    NSMenu *mainMenu = [NSMenu new];
    
    NSMenuItem *appItem = [mainMenu addItemWithTitle:@"App" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    
    NSMenuItem *editItem = [mainMenu addItemWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = editMenu;
    
    NSApp.mainMenu = mainMenu;
}
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
