/*
 ===========================================================================
 Gemini macOS Client (Eye-Care Light Theme & Paper-like Mode)
 
 [功能特点]
 1. 启动即全屏：沉浸式阅读体验
 2. 护眼模式：暖白/羊皮纸背景，低对比度文字
 3. TextKit 2：高性能文本渲染
 4. 历史记录：自动保存聊天记录到 /tmp
 
 [编译命令]
 clang++ -O3 -fobjc-arc -framework Cocoa -framework Foundation -framework UniformTypeIdentifiers main.mm -o Gemini
 
 [运行命令]
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
// 注意：模型名称可能会随时间更新，请根据 Google AI Studio 最新文档调整
static NSString *const kModelEndpoint = @"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent?key=";

// --- 字体与排版配置 ---
#define FONT_SIZE_TEXT   16.0  // 正文 16pt，适合阅读
#define FONT_SIZE_HEADER 17.0  // 标题略大
#define LINE_HEIGHT_MULT 1.25  // 1.25倍行高，增加呼吸感

// --- 护眼配色方案 (暖色调/纸张感) ---

// 背景：暖白/羊皮纸色 (Hex: #FAF9F6) - 核心护眼色
#define COLOR_BG_PAPER [NSColor colorWithSRGBRed:0.98 green:0.976 blue:0.965 alpha:1.0]

// 用户：深灰 (Hex: #333333) - 柔和的黑色，不刺眼
#define COLOR_USER   [NSColor colorWithSRGBRed:0.20 green:0.20 blue:0.20 alpha:1.0]

// 模型：深蓝灰 (Hex: #2C3E50) - 用于区分角色，增强可读性
#define COLOR_MODEL  [NSColor colorWithSRGBRed:0.17 green:0.24 blue:0.31 alpha:1.0]

// 思考：暖灰色 (Hex: #7F8C8D) - 低对比度，表示后台过程
#define COLOR_THINK  [NSColor colorWithSRGBRed:0.50 green:0.55 blue:0.55 alpha:1.0]

// 系统信息
#define COLOR_SYSTEM [NSColor colorWithSRGBRed:0.60 green:0.60 blue:0.60 alpha:1.0]
#define COLOR_ERROR  [NSColor colorWithSRGBRed:0.75 green:0.22 blue:0.17 alpha:1.0]

// ==========================================
// 2. ChatWindowController (核心逻辑)
// ==========================================
@interface ChatWindowController : NSWindowController <NSWindowDelegate, NSTextFieldDelegate>

// TextKit 组件
@property (strong) NSTextView *textView;
@property (strong) NSTextContentStorage *textContentStorage;
@property (strong) NSTextLayoutManager *textLayoutManager;
@property (strong) NSTextContainer *textContainer;

// 逻辑组件
@property (strong) NSMutableArray<NSDictionary *> *chatHistory;
@property (strong) NSTextField *inputField;
@property (strong) NSButton *sendButton;

// 视觉组件
@property (strong) NSVisualEffectView *effectView;

@end

@implementation ChatWindowController

- (instancetype)init {
    // 1. 创建窗口框架
    NSRect frame = NSMakeRect(0, 0, 1000, 800);
    
    NSUInteger style = NSWindowStyleMaskTitled |
                       NSWindowStyleMaskClosable |
                       NSWindowStyleMaskResizable |
                       NSWindowStyleMaskMiniaturizable |
                       NSWindowStyleMaskFullSizeContentView; // 内容充满标题栏
    
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    
    // 2. 窗口设置
    window.title = @"Gemini Reader";
    window.minSize = NSMakeSize(600, 500);
    // 关键：允许全屏
    window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    
    // 透明化基础设置
    window.opaque = NO;
    window.backgroundColor = [NSColor clearColor];
    window.titlebarAppearsTransparent = YES;
    
    // 强制使用浅色外观 (Aqua) 以配合暖色纸张主题
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
    // A. 背景层：毛玻璃 + 暖色滤镜
    // ---------------------------------------------------------
    _effectView = [[NSVisualEffectView alloc] initWithFrame:bounds];
    _effectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    
    // 使用 UnderPageBackground，这在浅色模式下通常是浅灰白色
    _effectView.material = NSVisualEffectMaterialUnderPageBackground;
    _effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    _effectView.state = NSVisualEffectStateActive;
    
    window.contentView = _effectView;
    
    // 添加一个暖白色的半透明层覆盖在毛玻璃上
    // 作用：无论壁纸是什么颜色，都能保证背景是柔和的暖纸色
    NSView *tintView = [[NSView alloc] initWithFrame:bounds];
    tintView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    tintView.wantsLayer = YES;
    // 0.85 的透明度：让暖色为主，透出 15% 的背景模糊
    tintView.layer.backgroundColor = [COLOR_BG_PAPER colorWithAlphaComponent:0.85].CGColor;
    [_effectView addSubview:tintView];
    
    // ---------------------------------------------------------
    // B. 文本区域 (TextKit 2)
    // ---------------------------------------------------------
    // 留出上下边距，中间区域用于显示
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(30, 80, bounds.size.width - 60, bounds.size.height - 110)];
    scrollView.hasVerticalScroller = YES;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.drawsBackground = NO; // 透明，透出下方的 tintView
    
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
    _textView.textContainerInset = NSMakeSize(10, 20);
    _textView.font = [NSFont systemFontOfSize:FONT_SIZE_TEXT];
    _textView.drawsBackground = NO; // 关键：透明
    
    scrollView.documentView = _textView;
    [_effectView addSubview:scrollView];
    
    // ---------------------------------------------------------
    // C. 底部输入区
    // ---------------------------------------------------------
    CGFloat bottomY = 30; // 稍微抬高一点
    CGFloat buttonHeight = 32;
    CGFloat rightMargin = 30;
    
    _inputField = [[NSTextField alloc] initWithFrame:NSMakeRect(30, bottomY, 600, buttonHeight)];
    _inputField.placeholderString = @"Ask Gemini...";
    _inputField.font = [NSFont systemFontOfSize:14];
    _inputField.bezelStyle = NSTextFieldRoundedBezel;
    _inputField.delegate = self;
    _inputField.target = self;
    _inputField.action = @selector(onEnterPressed);
    _inputField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    _inputField.wantsLayer = YES;
    _inputField.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.6].CGColor;
    
    [_effectView addSubview:_inputField];
    
    // 按钮布局
    CGFloat btnX = 640;
    
    _sendButton = [NSButton buttonWithTitle:@"Send" target:self action:@selector(onSendClicked)];
    _sendButton.bezelStyle = NSBezelStyleRounded;
    _sendButton.frame = NSMakeRect(btnX, bottomY, 70, buttonHeight);
    _sendButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [_effectView addSubview:_sendButton];
    
    NSButton *uploadBtn = [NSButton buttonWithTitle:@"Upload" target:self action:@selector(onUploadClicked)];
    uploadBtn.bezelStyle = NSBezelStyleRounded;
    uploadBtn.frame = NSMakeRect(btnX + 80, bottomY, 70, buttonHeight);
    uploadBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [_effectView addSubview:uploadBtn];
    
    NSButton *clearBtn = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(onClearClicked)];
    clearBtn.bezelStyle = NSBezelStyleRounded;
    clearBtn.frame = NSMakeRect(btnX + 160, bottomY, 70, buttonHeight);
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
            [self appendLog:@"Thinking" content:part[@"thought"] color:COLOR_THINK];
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
    // 1. 设置段落样式，行间距更宽松
    NSMutableParagraphStyle *paraStyle = [[NSMutableParagraphStyle alloc] init];
    paraStyle.lineBreakMode = NSLineBreakByWordWrapping;
    paraStyle.lineHeightMultiple = LINE_HEIGHT_MULT; 
    
    NSMutableAttributedString *mas = [[NSMutableAttributedString alloc] init];
    
    // 2. 标题样式
    NSDictionary *headerAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:FONT_SIZE_HEADER],
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: paraStyle
    };
    [mas appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n", header] attributes:headerAttrs]];
    
    // 3. 内容样式
    if (content) {
        NSDictionary *contentAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:FONT_SIZE_TEXT],
            NSForegroundColorAttributeName: color,
            NSParagraphStyleAttributeName: paraStyle
        };
        [mas appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n", content] attributes:contentAttrs]];
    }
    
    NSTextStorage *ts = self.textContentStorage.textStorage;
    [ts beginEditing];
    [ts appendAttributedString:mas];
    
    // 增加一个额外的空行分割
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
// 6. App Entry (程序入口与委托)
// ==========================================

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) ChatWindowController *windowController;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    [self setupMainMenu];
    
    self.windowController = [[ChatWindowController alloc] init];
    [self.windowController showWindow:self];
    
    // 1. 激活应用并将窗口前置
    [NSApp activateIgnoringOtherApps:YES];
    [self.windowController.window makeKeyAndOrderFront:nil];
    
    // 2. 立即触发全屏模式 (修改点)
    [self.windowController.window toggleFullScreen:nil];
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
