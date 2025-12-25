// 编译命令: clang -O3 -framework Cocoa -framework QuartzCore -framework PDFKit -framework UniformTypeIdentifiers -fobjc-arc main.m -o MiniPDF

#import <Cocoa/Cocoa.h>
#import <PDFKit/PDFKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// --- 自定义 PDF 视图控制器 ---
@interface MyPDFView : PDFView
@end

@implementation MyPDFView
// 如果需要自定义键盘快捷键，可以在这里重写
- (void)keyDown:(NSEvent *)event {
    uint16_t keyCode = [event keyCode];
    if (keyCode == 49) { // 空格翻页
        [self scrollPageDown:nil];
    } else {
        [super keyDown:event];
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

    // 2. 初始化 PDFView (PDFKit 核心类)
    self.pdfView = [[MyPDFView alloc] initWithFrame:[self.window contentView].bounds];
    
    // --- 核心设置：开启文字交互和适配 ---
    self.pdfView.autoScales = YES;                          // 自动缩放
    self.pdfView.displayMode = kPDFDisplaySinglePageContinuous; // 连续滚动模式（最适合按宽度阅读）
    self.pdfView.displayDirection = kPDFDisplayDirectionVertical;
    self.pdfView.displaysPageBreaks = YES;
    [self.pdfView setDisplaysAsBook:NO];
    
    // 设置背景色
    self.pdfView.backgroundColor = [NSColor darkGrayColor];
    
    // 允许文字选择 (PDFView 默认开启)
    // 用户可以直接用鼠标划选文字，Cmd+C 复制
    
    [self.pdfView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [self.window setContentView:self.pdfView];

    // 3. 全屏启动逻辑
    [self.window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
    [self.window makeKeyAndOrderFront:nil];
    [self.window toggleFullScreen:nil];

    [self.window makeFirstResponder:self.pdfView];
    [NSApp activateIgnoringOtherApps:YES];

    // 4. 加载文件逻辑
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
        // 强制执行一次“适配宽度”
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.pdfView setAutoScales:YES];
        });
    }
}

// 窗口大小改变时，PDFKit 的 autoScales 会自动处理宽度适配
- (void)windowDidResize:(NSNotification *)notification {
    // PDFKit 会自动处理大部分缩放逻辑
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
