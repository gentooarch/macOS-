// 编译命令: clang -O3 -framework Cocoa -framework QuartzCore -framework PDFKit -framework UniformTypeIdentifiers -fobjc-arc main.m -o MiniPDF

#import <Cocoa/Cocoa.h>
#import <PDFKit/PDFKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// --- 自定义 PDF 视图控制器 ---
@interface MyPDFView : PDFView {
    NSMutableString *_inputBuffer; // 用于存储输入的页码数字
}
@end

@implementation MyPDFView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _inputBuffer = [NSMutableString string];
    }
    return self;
}

// 处理键盘事件
- (void)keyDown:(NSEvent *)event {
    NSString *chars = [event charactersIgnoringModifiers];
    uint16_t keyCode = [event keyCode];

    // 1. 'q' 键退出
    if ([chars isEqualToString:@"q"]) {
        [NSApp terminate:nil];
        return;
    }

    // 2. 空格键翻页 (保留原逻辑)
    if (keyCode == 49) {
        [self scrollPageDown:nil];
        [_inputBuffer setString:@""]; // 按其他功能键时清空数字缓冲区
        return;
    }

    // 3. 数字键处理 (0-9)
    if (chars.length > 0) {
        unichar c = [chars characterAtIndex:0];
        if (c >= '0' && c <= '9') {
            [_inputBuffer appendString:chars];
            return;
        }
    }

    // 4. 'g' 键跳转
    if ([chars isEqualToString:@"g"]) {
        if (_inputBuffer.length > 0) {
            NSInteger pageNum = [_inputBuffer integerValue];
            [self jumpToPage:pageNum];
            [_inputBuffer setString:@""]; // 跳转后清空缓冲区
        } else {
            // 如果直接按 g，通常 MuPDF 是回到第一页
            [self jumpToPage:1];
        }
        return;
    }

    // 如果按了其他非功能键，清空缓冲区防止误触
    if (chars.length > 0) {
        [_inputBuffer setString:@""];
    }

    [super keyDown:event];
}

// 执行跳转逻辑
- (void)jumpToPage:(NSInteger)pageNumber {
    PDFDocument *doc = self.document;
    if (!doc) return;

    // PDFKit 的索引从 0 开始，用户输入通常从 1 开始
    NSInteger targetIndex = pageNumber - 1;
    
    // 边界检查
    if (targetIndex < 0) targetIndex = 0;
    if (targetIndex >= doc.pageCount) targetIndex = doc.pageCount - 1;

    PDFPage *targetPage = [doc pageAtIndex:targetIndex];
    if (targetPage) {
        [self goToPage:targetPage];
    }
}

@end

// --- 应用程序代理 ---
@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (strong) NSWindow *window;
@property (strong) MyPDFView *pdfView;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    // 1. 创建窗口
    NSRect frame = NSMakeRect(0, 0, 1000, 800);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskResizable | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable)
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    [self.window setTitle:@"MiniPDF - Text Interactive"];
    [self.window setDelegate:self];

    // 2. 初始化 MyPDFView
    self.pdfView = [[MyPDFView alloc] initWithFrame:[self.window contentView].bounds];
    
    self.pdfView.autoScales = YES;
    self.pdfView.displayMode = kPDFDisplaySinglePageContinuous;
    self.pdfView.displayDirection = kPDFDisplayDirectionVertical;
    self.pdfView.displaysPageBreaks = YES;
    [self.pdfView setDisplaysAsBook:NO];
    self.pdfView.backgroundColor = [NSColor darkGrayColor];
    
    [self.pdfView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [self.window setContentView:self.pdfView];

    // 3. 全屏启动
    [self.window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
    [self.window makeKeyAndOrderFront:nil];
    [self.window toggleFullScreen:nil];

    [self.window makeFirstResponder:self.pdfView];
    [NSApp activateIgnoringOtherApps:YES];

    // 4. 加载文件
    NSArray *args = [[NSProcessInfo processInfo] arguments];
    if (args.count > 1) {
        [self loadPDFAtPath:args[1]];
    } else {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.allowedContentTypes = @[[UTType typeWithIdentifier:@"com.adobe.pdf"]];
        if ([panel runModal] == NSModalResponseOK) {
            [self loadPDFAtPath:[[panel URL] path]];
        }
    }
}

- (void)loadPDFAtPath:(NSString *)path {
    NSURL *url = [NSURL fileURLWithPath:path];
    PDFDocument *document = [[PDFDocument alloc] initWithURL:url];
    if (document) {
        self.pdfView.document = document;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.pdfView setAutoScales:YES];
        });
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
