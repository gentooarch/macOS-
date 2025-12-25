// 编译命令: clang -O3 -framework Cocoa -framework QuartzCore -framework UniformTypeIdentifiers -fobjc-arc main.m -o MiniPDF

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
- (void)resizeToFitWidth;
@end

@implementation EfficientPDFView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [[NSColor darkGrayColor] CGColor]; // 背景深色，方便看清边界
        
        _contentLayer = [CALayer layer];
        _contentLayer.contentsGravity = kCAGravityResizeAspect;
        _contentLayer.actions = @{@"contents": [NSNull null], @"bounds": [NSNull null], @"position": [NSNull null]};
        // 关键：设置图层的缩放倍率
        _contentLayer.contentsScale = [[NSScreen mainScreen] backingScaleFactor];
        [self.layer addSublayer:_contentLayer];
    }
    return self;
}

// 强制不响应横向滚动
- (void)resizeToFitWidth {
    if (!_document || !self.enclosingScrollView) return;

    CGPDFPageRef page = CGPDFDocumentGetPage(_document, _currentPage);
    if (!page) return;

    // 获取滚动视图实际可见的宽度（去掉滚动条后的空间）
    CGFloat availableWidth = self.enclosingScrollView.contentSize.width;
    
    CGRect pageRect = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
    CGFloat aspectRatio = pageRect.size.height / pageRect.size.width;
    CGFloat targetHeight = availableWidth * aspectRatio;

    // 更新视图大小：宽度严格等于容器宽，高度按比例伸缩
    [self setFrameSize:NSMakeSize(availableWidth, targetHeight)];
    _contentLayer.frame = self.bounds;
    
    [self renderCurrentPageAsync];
}

- (void)loadDocument:(NSString *)path {
    if (_document) CGPDFDocumentRelease(_document);
    _document = CGPDFDocumentCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path]);
    
    if (_document) {
        _totalPages = CGPDFDocumentGetNumberOfPages(_document);
        _currentPage = 1;
        [self resizeToFitWidth];
    }
}

- (void)renderCurrentPageAsync {
    if (!_document) return;
    
    size_t pageNum = _currentPage;
    CGPDFDocumentRef doc = _document;
    CGPDFDocumentRetain(doc);
    
    CGFloat screenScale = [[NSScreen mainScreen] backingScaleFactor];
    // 使用当前视图的实际宽度进行渲染计算
    CGSize targetSize = self.bounds.size; 

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CGPDFPageRef page = CGPDFDocumentGetPage(doc, pageNum);
        if (!page) { CGPDFDocumentRelease(doc); return; }

        CGRect pageRect = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
        
        // 渲染比例计算
        CGFloat renderScale = (targetSize.width / pageRect.size.width) * screenScale;
        
        size_t w = targetSize.width * screenScale;
        size_t h = targetSize.height * screenScale;
        
        if (w < 1 || h < 1) { CGPDFDocumentRelease(doc); return; }

        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef bctx = CGBitmapContextCreate(NULL, w, h, 8, 0, colorSpace, kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(colorSpace);
        
        if (!bctx) { CGPDFDocumentRelease(doc); return; }

        // 填充白色背景（PDF 页面通常是透明或白色的）
        CGContextSetRGBFillColor(bctx, 1, 1, 1, 1);
        CGContextFillRect(bctx, CGRectMake(0, 0, w, h));

        CGContextScaleCTM(bctx, renderScale, renderScale);
        CGContextDrawPDFPage(bctx, page);
        
        CGImageRef image = CGBitmapContextCreateImage(bctx);
        CGContextRelease(bctx);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_contentLayer.contents = (__bridge id)image;
            CGImageRelease(image);
            CGPDFDocumentRelease(doc);
        });
    });
}

- (void)nextPage {
    if (_currentPage < _totalPages) { 
        _currentPage++; 
        [self resizeToFitWidth];
        [self scrollToTop];
    }
}

- (void)prevPage {
    if (_currentPage > 1) { 
        _currentPage--; 
        [self resizeToFitWidth];
        [self scrollToTop];
    }
}

- (void)scrollToTop {
    NSPoint topPoint = NSMakePoint(0, self.frame.size.height - self.enclosingScrollView.contentSize.height);
    if (topPoint.y < 0) topPoint.y = 0;
    [[self.enclosingScrollView contentView] scrollToPoint:topPoint];
    [self.enclosingScrollView reflectScrolledClipView:[self.enclosingScrollView contentView]];
}

- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event {
    uint16_t keyCode = [event keyCode];
    if (keyCode == 124 || keyCode == 49) [self nextPage]; // 右 / 空格
    else if (keyCode == 123) [self prevPage];             // 左
}
@end

// --- 应用程序代理 ---
@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (strong) NSWindow *window;
@property (strong) EfficientPDFView *pdfView;
@property (strong) NSScrollView *scrollView;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    
    // 创建初始窗口
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 800)
                                             styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskResizable | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable)
                                               backing:NSBackingStoreBuffered defer:NO];
    [self.window setTitle:@"MiniPDF - Fixed Width"];
    [self.window setDelegate:self];
    
    // 设置滚动视图
    self.scrollView = [[NSScrollView alloc] initWithFrame:[self.window contentView].bounds];
    [self.scrollView setHasVerticalScroller:YES];
    [self.scrollView setHasHorizontalScroller:NO]; // 彻底禁用横向滚动条
    [self.scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [self.scrollView setDrawsBackground:YES];
    [self.scrollView setBackgroundColor:[NSColor darkGrayColor]];

    // 设置 PDF 视图
    self.pdfView = [[EfficientPDFView alloc] initWithFrame:self.scrollView.bounds];
    // 关键：不要给 pdfView 设置 WidthSizable 的 AutoresizingMask，
    // 因为我们要通过代码精确控制它的 Frame 宽度。
    
    [self.scrollView setDocumentView:self.pdfView];
    [self.window setContentView:self.scrollView];
    
    // 全屏启动逻辑
    [self.window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
    [self.window makeKeyAndOrderFront:nil];
    [self.window toggleFullScreen:nil];

    [self.window makeFirstResponder:self.pdfView];
    
    // 加载文件
    NSArray *args = [[NSProcessInfo processInfo] arguments];
    if (args.count > 1) {
        [self.pdfView loadDocument:args[1]];
    } else {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.allowedContentTypes = @[[UTType typeWithIdentifier:@"com.adobe.pdf"]];
        if ([panel runModal] == NSModalResponseOK) {
            [self.pdfView loadDocument:[[panel URL] path]];
        }
    }
}

// 核心：当窗口大小改变（包括进入全屏完成时），重新计算适配宽度
- (void)windowDidResize:(NSNotification *)notification {
    [self.pdfView resizeToFitWidth];
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
