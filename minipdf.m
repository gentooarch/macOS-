//clang -O3 -framework Cocoa -framework QuartzCore -framework UniformTypeIdentifiers -fobjc-arc main.m -o MiniPDF
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// --- 高能效 PDF 渲染视图 ---
@interface EfficientPDFView : NSView {
    CGPDFDocumentRef _document;
    size_t _currentPage;
    size_t _totalPages;
    CALayer *_contentLayer;
}
- (void)loadDocument:(NSString *)path;
- (void)nextPage;
- (void)prevPage;
@end

@implementation EfficientPDFView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        _contentLayer = [CALayer layer];
        _contentLayer.contentsGravity = kCAGravityResizeAspect;
        // 禁用隐式动画，提高响应速度
        _contentLayer.actions = @{@"contents": [NSNull null]};
        [self.layer addSublayer:_contentLayer];
    }
    return self;
}

- (void)setFrame:(NSRect)frame {
    [super setFrame:frame];
    _contentLayer.frame = self.bounds;
    [self renderCurrentPageAsync];
}

- (void)loadDocument:(NSString *)path {
    if (_document) CGPDFDocumentRelease(_document);
    
    // 修正：使用 NSURL 自动处理相对路径和绝对路径
    NSURL *url = [NSURL fileURLWithPath:path];
    _document = CGPDFDocumentCreateWithURL((__bridge CFURLRef)url);
    
    if (_document) {
        _totalPages = CGPDFDocumentGetNumberOfPages(_document);
        _currentPage = 1;
        NSLog(@"PDF Loaded: %zu pages", _totalPages);
        [self renderCurrentPageAsync];
    } else {
        NSLog(@"Failed to load PDF at path: %@", path);
    }
}

- (void)renderCurrentPageAsync {
    if (!_document) return;
    
    size_t pageNum = _currentPage;
    CGPDFDocumentRef doc = _document;
    CGPDFDocumentRetain(doc);
    
    CGFloat screenScale = [[NSScreen mainScreen] backingScaleFactor];
    // 避免在后台线程访问 self.bounds，提前获取尺寸
    CGSize layerSize = self.bounds.size; 

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CGPDFPageRef page = CGPDFDocumentGetPage(doc, pageNum);
        if (!page) { CGPDFDocumentRelease(doc); return; }

        CGRect pageRect = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
        // 计算缩放比例：将 PDF 完整放入视图中
        CGFloat scaleX = layerSize.width / pageRect.size.width;
        CGFloat scaleY = layerSize.height / pageRect.size.height;
        CGFloat fitScale = MIN(scaleX, scaleY);
        
        // 渲染倍率：2.0 保证清晰度，若追求极致速度可降为 1.0
        CGFloat renderScale = fitScale * screenScale; 
        
        size_t width = pageRect.size.width * renderScale;
        size_t height = pageRect.size.height * renderScale;
        
        // 防止无效尺寸
        if (width < 1 || height < 1) { CGPDFDocumentRelease(doc); return; }

        CGContextRef bctx = CGBitmapContextCreate(NULL, width, height, 8, 0, 
                                                 CGColorSpaceCreateDeviceRGB(), 
                                                 kCGImageAlphaPremultipliedLast);
        
        if (!bctx) { CGPDFDocumentRelease(doc); return; }

        CGContextSetInterpolationQuality(bctx, kCGInterpolationDefault);
        CGContextScaleCTM(bctx, renderScale, renderScale);
        CGContextDrawPDFPage(bctx, page);

        CGImageRef image = CGBitmapContextCreateImage(bctx);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_contentLayer.contents = (__bridge id)image;
            CGImageRelease(image);
            CGContextRelease(bctx);
            CGPDFDocumentRelease(doc);
        });
    });
}

- (void)nextPage {
    if (_currentPage < _totalPages) { _currentPage++; [self renderCurrentPageAsync]; }
}

- (void)prevPage {
    if (_currentPage > 1) { _currentPage--; [self renderCurrentPageAsync]; }
}

- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event {
    uint16_t keyCode = [event keyCode];
    if (keyCode == 124 || keyCode == 49) [self nextPage]; // 右箭头 / 空格
    else if (keyCode == 123) [self prevPage];             // 左箭头
}
@end

// --- 应用程序代理 ---
@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (strong) NSWindow *window;
@property (strong) EfficientPDFView *pdfView;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // 修正：强制将应用设为普通应用（显示 Dock 图标和菜单栏），否则命令行启动不会显示窗口
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    
    NSRect frame = NSMakeRect(0, 0, 800, 1000);
    // 居中显示
    NSRect screenRect = [[NSScreen mainScreen] visibleFrame];
    frame.origin.x = (screenRect.size.width - frame.size.width) / 2;
    frame.origin.y = (screenRect.size.height - frame.size.height) / 2;

    self.window = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskResizable | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable)
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    [self.window setTitle:@"Ultra-Efficient PDF"];
    [self.window setDelegate:self];
    
    self.pdfView = [[EfficientPDFView alloc] initWithFrame:[self.window contentView].bounds];
    // 设置自动调整大小，确保拖拽窗口时 View 跟着变
    [self.pdfView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    [self.window setContentView:self.pdfView];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.pdfView];
    
    // 强制前台激活
    [NSApp activateIgnoringOtherApps:YES];
    
    // 处理命令行参数
    NSArray *args = [[NSProcessInfo processInfo] arguments];
    if (args.count > 1) {
        NSString *filePath = args[1];
        [self.pdfView loadDocument:filePath];
    } else {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.allowedContentTypes = @[[UTType typeWithIdentifier:@"com.adobe.pdf"]];
        if ([panel runModal] == NSModalResponseOK) {
            [self.pdfView loadDocument:[[panel URL] path]];
        }
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

// --- 主函数 ---
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
