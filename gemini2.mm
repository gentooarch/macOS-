/*
 ===========================================================================
 Gemini macOS Client (Light Theme & Readability Optimized)
 
 编译命令:
 clang++ -O3 -fobjc-arc -framework Cocoa -framework Foundation -framework UniformTypeIdentifiers main.mm -o Gemini
 
 运行命令:
 ./Gemini "你的_API_KEY"
 ===========================================================================
 */

#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// ==========================================
// 1. 全局配置与常量
// ==========================================
static NSString *g_apiKey = @"key";
static NSString *const kHistoryFilePath = @"/tmp/gemini_chat_history.json";
static NSString *const kModelEndpoint = @"https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key=";

// --- 字体与排版配置 ---
#define FONT_SIZE_TEXT   16.0  // 正文增大至16，适合阅读
#define FONT_SIZE_HEADER 16.0  // 标题字号
#define LINE_HEIGHT_MULT 1.25  // 1.25倍行高，增加呼吸感

// --- 护眼浅色配色方案 ---
// 用户：深海蓝，沉稳清晰
#define COLOR_USER   [NSColor colorWithSRGBRed:0.05 green:0.25 blue:0.45 alpha:1.0]
// 模型：墨灰 (避免纯黑#000000带来的强烈反差)
#define COLOR_MODEL  [NSColor colorWithSRGBRed:0.15 green:0.15 blue:0.15 alpha:1.0]
// 思考：暖灰色
#define COLOR_THINK  [NSColor colorWithSRGBRed:0.55 green:0.55 blue:0.53 alpha:1.0]
// 系统：次级标签色
#define COLOR_SYSTEM [NSColor secondaryLabelColor]
// 错误：柔和红
#define COLOR_ERROR  [NSColor systemRedColor]

// ==========================================
// 2. ChatWindowController (核心逻辑)
// ==========================================
@interface ChatWindowController : NSWindowController <NSWindowDelegate, NSTextFieldDelegate>

// TextKit 2 组件
@property (strong) NSTextView *textView;
@property (strong) NSTextContentStorage *textContentStorage;
@property (strong) NSTextLayoutManager *textLayoutManager;
@property (strong) NSTextContainer *textContainer;

// 逻辑组件
@property (strong) NSMutableArray<NSDictionary *> *chatHistory;
@property (strong) NSTextField *inputField;
@property (strong) NSButton *sendButton;

// 背景特效视图
@property (strong) NSVisualEffectView *effectView;

@end

@implementation ChatWindowController

- (instancetype)init {
    // 1. 创建窗口框架
    NSRect frame = NSMakeRect(0, 0, 950, 750); //稍微加大窗口默认尺寸
    
    NSUInteger style = NSWindowStyleMaskTitled |
                       NSWindowStyleMaskClosable |
                       NSWindowStyleMaskResizable |
                       NSWindowStyleMaskMiniaturizable |
                       NSWindowStyleMaskFullSizeContentView;
    
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    
    // 2. 窗口设置
    window.title = @"Gemini Reader";
    window.minSize = NSMakeSize(600, 400);
    window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    
    // 透明化基础设置
    window.opaque = NO;
    window.backgroundColor = [NSColor clearColor];
    window.titlebarAppearsTransparent = YES;
    
    // 关键：强制窗口使用浅色外观 (Aqua)，确保字体和控件在浅色背景下清晰可见
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    
    self = [super initWithWindow:window];
    if (self) {
        _chatHistory = [NSMutableArray array];
        [self setupUI];
        [self loadHistoryFromDisk]; 
    }
    return self;
}

- (void)setupUI {
    NSWindow *window = self.window;
    NSView *rootView = window.contentView;
    NSRect bounds = rootView.bounds;

    // ---------------------------------------------------------
    // A. 添加 Metal/VisualEffect 毛玻璃背景
    // ---------------------------------------------------------
    _effectView = [[NSVisualEffectView alloc] initWithFrame:bounds];
    _effectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    
    // 修改：使用 Sidebar 材质，在浅色模式下呈现为通透的磨砂白/浅灰，非常适合阅读
    _effectView.material = NSVisualEffectMaterialSidebar;
    _effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    _effectView.state = NSVisualEffectStateActive;
    
    window.contentView = _effectView;
    
    // ---------------------------------------------------------
    // B. TextKit 2 初始化栈
    // ---------------------------------------------------------
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(30, 70, bounds.size.width - 60, bounds.size.height - 100)];
    scrollView.hasVerticalScroller = YES;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.drawsBackground = NO; // 透明
    
    _textContentStorage = [[NSTextContentStorage alloc] init];
    _textLayoutManager = [[NSTextLayoutManager alloc] init];
    [_textContentStorage addTextLayoutManager:_textLayoutManager];
    
    NSSize contentSize = scrollView.contentSize;
    _textContainer = [[NSTextContainer alloc] initWithSize:NSMakeSize(contentSize.width, FLT_MAX)];
    _textContainer.widthTracksTextView = YES;
    _textContainer.heightTracksTextView = NO;
    _textLayoutManager.textContainer = _textContainer;
    
    _textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height) textContainer:_textContainer];
    _textView.minSize = NSMakeSize(0.0, contentSize.height);
    _textView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    _textView.verticallyResizable = YES;
    _textView.horizontallyResizable = NO;
    _textView.autoresizingMask = NSViewWidthSizable;
    _textView.editable = NO;
    _textView.selectable = YES;
    _textView.textContainerInset = NSMakeSize(10, 20); // 增加顶部留白
    _textView.font = [NSFont systemFontOfSize:FONT_SIZE_TEXT];
    
    _textView.drawsBackground = NO; // 透明
    
    scrollView.documentView = _textView;
    [_effectView addSubview:scrollView];
    
    // ---------------------------------------------------------
    // C. 输入区域
    // ---------------------------------------------------------
    CGFloat bottomY = 20;
    CGFloat buttonHeight = 36; // 稍微加高按钮
    
    _inputField = [[NSTextField alloc] initWithFrame:NSMakeRect(30, bottomY, 600, buttonHeight)];
    _inputField.placeholderString = @"Ask something...";
    _inputField.font = [NSFont systemFontOfSize:FONT_SIZE_TEXT]; // 输入框字体也加大
    _inputField.bezelStyle = NSTextFieldRoundedBezel;
    _inputField.delegate = self;
    _inputField.target = self;
    _inputField.action = @selector(onEnterPressed);
    _inputField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [_effectView addSubview:_inputField];
    
    _sendButton = [NSButton buttonWithTitle:@"Send" target:self action:@selector(onSendClicked)];
    _sendButton.bezelStyle = NSBezelStyleRounded;
    _sendButton.frame = NSMakeRect(640, bottomY, 70, buttonHeight);
    _sendButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    _sendButton.font = [NSFont systemFontOfSize:14]; // 按钮字体适中
    [_effectView addSubview:_sendButton];
    
    NSButton *uploadBtn = [NSButton buttonWithTitle:@"Upload" target:self action:@selector(onUploadClicked)];
    uploadBtn.bezelStyle = NSBezelStyleRounded;
    uploadBtn.frame = NSMakeRect(720, bottomY, 80, buttonHeight);
    uploadBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [_effectView addSubview:uploadBtn];
    
    NSButton *clearBtn = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(onClearClicked)];
    clearBtn.bezelStyle = NSBezelStyleRounded;
    clearBtn.frame = NSMakeRect(810, bottomY, 80, buttonHeight);
    clearBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [_effectView addSubview:clearBtn];
}

// ==========================================
// 3. 历史记录管理
// ==========================================

- (void)loadHistoryFromDisk {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kHistoryFilePath]) return;
    
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:kHistoryFilePath options:0 error:&error];
    if (data) {
        NSArray *jsonArr = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
        if (jsonArr) {
            self.chatHistory = [jsonArr mutableCopy];
            [self appendLog:@"[System]" content:[NSString stringWithFormat:@"Loaded %lu messages", (unsigned long)jsonArr.count] color:COLOR_SYSTEM];
            
            for (NSDictionary *msg in self.chatHistory) {
                NSString *role = msg[@"role"];
                NSString *text = @"";
                NSArray *parts = msg[@"parts"];
                if (parts.count > 0) text = parts[0][@"text"];
                
                NSColor *color = [role isEqualToString:@"user"] ? COLOR_USER : COLOR_MODEL;
                NSString *displayRole = [role isEqualToString:@"user"] ? @"You" : @"Gemini";
                [self appendLog:displayRole content:text color:color];
            }
            [self scrollToBottom];
        }
    }
}

- (void)saveHistoryToDisk {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.chatHistory options:NSJSONWritingPrettyPrinted error:&error];
    if (data) [data writeToFile:kHistoryFilePath atomically:YES];
}

// ==========================================
// 4. 核心逻辑与网络
// ==========================================

- (void)onEnterPressed { [self onSendClicked]; }

- (void)onSendClicked {
    NSString *input = self.inputField.stringValue;
    if (input.length == 0) return;
    
    if ([input isEqualToString:@"/clear"]) {
        [self onClearClicked];
        self.inputField.stringValue = @"";
        return;
    }
    
    [self processUserMessage:input];
    self.inputField.stringValue = @"";
}

- (void)processUserMessage:(NSString *)text {
    [self appendLog:@"You" content:text color:COLOR_USER];
    NSDictionary *userMsg = @{ @"role": @"user", @"parts": @[ @{ @"text": text } ] };
    [self.chatHistory addObject:userMsg];
    [self saveHistoryToDisk];
    [self callGeminiAPI];
}

- (void)onUploadClicked {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[UTTypePlainText, UTTypeSourceCode, UTTypeJSON, UTTypeXML, UTTypeHTML, UTTypeSwiftSource, UTTypeObjectiveCSource];
    
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            NSURL *url = [panel URLs].firstObject;
            NSError *readError = nil;
            NSString *content = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:&readError];
            if (content) {
                NSString *msg = [NSString stringWithFormat:@"[File Upload: %@]\n\n%@", url.lastPathComponent, content];
                [self processUserMessage:msg];
            } else {
                [self appendLog:@"[Error]" content:readError.localizedDescription color:COLOR_ERROR];
            }
        }
    }];
}

- (void)onClearClicked {
    [self.chatHistory removeAllObjects];
    [self saveHistoryToDisk];
    
    NSTextStorage *ts = self.textContentStorage.textStorage;
    [ts beginEditing];
    [ts replaceCharactersInRange:NSMakeRange(0, ts.length) withString:@""];
    [ts endEditing];
    
    [self appendLog:@"[System]" content:@"History cleared." color:COLOR_SYSTEM];
}

- (void)callGeminiAPI {
    [self setUIEnabled:NO];
    
    NSURL *url = [NSURL URLWithString:[kModelEndpoint stringByAppendingString:g_apiKey]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    
    NSDictionary *payload = @{ @"contents": self.chatHistory };
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setUIEnabled:YES];
            if (error) {
                [self appendLog:@"[Network Error]" content:error.localizedDescription color:COLOR_ERROR];
                return;
            }
            [self parseResponse:data];
        });
    }] resume];
}

- (void)parseResponse:(NSData *)data {
    NSError *err = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    
    if (!json) {
        NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        [self appendLog:@"[Raw Error]" content:raw color:COLOR_ERROR];
        return;
    }
    
    if (json[@"error"]) {
        [self appendLog:@"[API Error]" content:json[@"error"][@"message"] color:COLOR_ERROR];
        return;
    }
    
    NSArray *candidates = json[@"candidates"];
    if (candidates.count == 0) return;
    
    NSArray *parts = candidates[0][@"content"][@"parts"];
    if (!parts) return;
    
    NSMutableString *fullText = [NSMutableString string];
    for (NSDictionary *part in parts) {
        if (part[@"thought"]) {
            [self appendLog:@"Thought" content:part[@"thought"] color:COLOR_THINK];
        }
        if (part[@"text"]) {
            [fullText appendString:part[@"text"]];
        }
    }
    
    if (fullText.length > 0) {
        [self appendLog:@"Gemini" content:fullText color:COLOR_MODEL];
        
        [self.chatHistory addObject:@{
            @"role": @"model",
            @"parts": @[ @{ @"text": [fullText copy] } ]
        }];
        [self saveHistoryToDisk];
    }
}

// ==========================================
// 5. 辅助方法 (样式优化重点)
// ==========================================

- (void)appendLog:(NSString *)header content:(NSString *)content color:(NSColor *)color {
    // 1. 设置段落样式，增加行间距和段后距
    NSMutableParagraphStyle *paraStyle = [[NSMutableParagraphStyle alloc] init];
    paraStyle.lineBreakMode = NSLineBreakByWordWrapping;
    paraStyle.paragraphSpacing = 16.0;      // 段落之间拉开距离
    paraStyle.lineHeightMultiple = LINE_HEIGHT_MULT; // 增加行高，减少密集感
    
    NSMutableAttributedString *mas = [[NSMutableAttributedString alloc] init];
    
    // 2. 标题样式 (Role Name)
    NSDictionary *headerAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:FONT_SIZE_HEADER],
        NSForegroundColorAttributeName: color, // 使用定义好的深蓝/深灰
        NSParagraphStyleAttributeName: paraStyle
    };
    [mas appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@:\n", header] attributes:headerAttrs]];
    
    // 3. 内容样式
    if (content) {
        NSDictionary *contentAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:FONT_SIZE_TEXT],
            NSForegroundColorAttributeName: color, // 正文也使用对应角色的颜色
            NSParagraphStyleAttributeName: paraStyle
        };
        [mas appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n", content] attributes:contentAttrs]];
    }
    
    NSTextStorage *ts = self.textContentStorage.textStorage;
    [ts beginEditing];
    [ts appendAttributedString:mas];
    
    // 分割线留白
    NSAttributedString *spacing = [[NSAttributedString alloc] initWithString:@"\n" attributes:@{NSParagraphStyleAttributeName: paraStyle}];
    [ts appendAttributedString:spacing];
    [ts endEditing];
    
    [self scrollToBottom];
}

- (void)scrollToBottom {
    [self.textLayoutManager ensureLayoutForRange:self.textContentStorage.documentRange];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.textView.string.length > 0) {
            [self.textView scrollRangeToVisible:NSMakeRange(self.textView.string.length, 0)];
        }
    });
}

- (void)setUIEnabled:(BOOL)enabled {
    self.inputField.enabled = enabled;
    self.sendButton.enabled = enabled;
}

@end

// ==========================================
// 6. App Entry
// ==========================================

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) ChatWindowController *windowController;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    [self setupMainMenu];
    
    self.windowController = [[ChatWindowController alloc] init];
    [self.windowController showWindow:self];
    
    [self.windowController.window toggleFullScreen:nil];
    
    [NSApp activateIgnoringOtherApps:YES];
    [self.windowController.window makeKeyAndOrderFront:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)setupMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] init];
    NSApp.mainMenu = mainMenu;
    
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appMenuItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    appMenuItem.submenu = appMenu;
    [appMenu addItemWithTitle:@"Quit Gemini" action:@selector(terminate:) keyEquivalent:@"q"];
    
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:editMenuItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    editMenuItem.submenu = editMenu;
    
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc > 1) g_apiKey = [NSString stringWithUTF8String:argv[1]];
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
