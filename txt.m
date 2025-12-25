#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

// --- Metal 背景渲染 ---
NSString *SHADER = @R"(
#include <metal_stdlib>
using namespace metal;
kernel void bg_kernel(texture2d<float, access::write> tex [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= tex.get_width() || gid.y >= tex.get_height()) return;
    tex.write(float4(0.96, 0.95, 0.86, 1.0), gid);
}
)";

@interface ReaderWindow : NSWindow <NSWindowDelegate, MTKViewDelegate>
@end

@implementation ReaderWindow {
    NSTextView *_textView;
    MTKView *_mtkView;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _pso;
    
    NSString *_fullText;
    NSMutableArray<NSValue *> *_pages;
    NSInteger _currentPage;
}

- (instancetype)initWithText:(NSString *)text {
    self = [super initWithContentRect:NSMakeRect(0, 0, 900, 700)
                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (self) {
        _fullText = (text && text.length > 0) ? text : @"(无内容)";
        _currentPage = 0;
        _pages = [NSMutableArray new];
        _device = MTLCreateSystemDefaultDevice();
        _queue = [_device newCommandQueue];
        
        [self setupMetal];
        [self setupUI];
        
        self.delegate = self;
        [self setTitle:@"Metal Reader - 使用 PageUp/PageDown 翻页"];
        [self setTitlebarAppearsTransparent:YES];
        [self center];
    }
    return self;
}

- (void)setupMetal {
    NSError *err;
    id<MTLLibrary> lib = [_device newLibraryWithSource:SHADER options:nil error:&err];
    id<MTLFunction> fn = [lib newFunctionWithName:@"bg_kernel"];
    _pso = [_device newComputePipelineStateWithFunction:fn error:&err];
}

- (void)setupUI {
    _mtkView = [[MTKView alloc] initWithFrame:self.contentView.bounds device:_device];
    _mtkView.delegate = self;
    _mtkView.framebufferOnly = NO;
    _mtkView.paused = YES;
    _mtkView.enableSetNeedsDisplay = YES;
    self.contentView = _mtkView;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:_mtkView.bounds];
    [scroll setDrawsBackground:NO];
    [scroll setHasVerticalScroller:NO];
    
    _textView = [[NSTextView alloc] initWithFrame:scroll.bounds];
    [_textView setEditable:NO];
    [_textView setSelectable:YES];
    [_textView setBackgroundColor:[NSColor clearColor]];
    
    // --- 关键设置：确保显示引擎没有额外边距 ---
    [_textView setTextContainerInset:NSMakeSize(50, 40)];
    _textView.textContainer.lineFragmentPadding = 0; // 禁用行左右内边距
    
    [scroll setDocumentView:_textView];
    [_mtkView addSubview:scroll];
    
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:_mtkView.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:_mtkView.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:_mtkView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:_mtkView.trailingAnchor]
    ]];
}

// 拦截 PageUp (116) 和 PageDown (121)
- (void)sendEvent:(NSEvent *)event {
    if (event.type == NSEventTypeKeyDown) {
        if (event.keyCode == 121) { // Page Down
            if (_currentPage < _pages.count - 1) {
                _currentPage++;
                [self updateContent];
            }
            return;
        } else if (event.keyCode == 116) { // Page Up
            if (_currentPage > 0) {
                _currentPage--;
                [self updateContent];
            }
            return;
        } else if (event.keyCode == 53) { // ESC
            [NSApp terminate:nil];
            return;
        }
    }
    [super sendEvent:event];
}

// 窗口完全激活后开始分页
- (void)becomeKeyWindow {
    [super becomeKeyWindow];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self paginate];
        [self updateContent];
    });
}

// 精确分页算法
- (void)paginate {
    [_pages removeAllObjects];
    
    // 获取文字显示区域的纯净尺寸
    NSSize containerSize = _textView.bounds.size;
    CGFloat insetWidth = _textView.textContainerInset.width * 2;
    CGFloat insetHeight = _textView.textContainerInset.height * 2;
    NSSize renderSize = NSMakeSize(containerSize.width - insetWidth, containerSize.height - insetHeight);

    // 统一属性（必须与 updateContent 保持完全一致）
    NSFont *font = [NSFont systemFontOfSize:22];
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.lineSpacing = 8;
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSParagraphStyleAttributeName: style };

    // 创建分页排版引擎
    NSTextStorage *textStorage = [[NSTextStorage alloc] initWithString:_fullText];
    [textStorage setAttributes:attrs range:NSMakeRange(0, textStorage.length)];
    
    NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
    NSTextContainer *textContainer = [[NSTextContainer alloc] initWithSize:renderSize];
    textContainer.lineFragmentPadding = 0; // 必须为 0
    
    [layoutManager addTextContainer:textContainer];
    [textStorage addLayoutManager:layoutManager];

    NSUInteger currentPos = 0;
    NSUInteger totalLen = _fullText.length;

    while (currentPos < totalLen) {
        // 强制布局
        [layoutManager ensureLayoutForTextContainer:textContainer];
        
        // 获取当前容器内可见的字形范围
        NSRange glyphRange = [layoutManager glyphRangeForBoundingRect:NSMakeRect(0, 0, renderSize.width, renderSize.height)
                                                      inTextContainer:textContainer];
        
        // 转换为字符范围
        NSRange charRange = [layoutManager characterRangeForGlyphRange:glyphRange actualGlyphRange:NULL];
        
        if (charRange.length == 0) break;

        [_pages addObject:[NSValue valueWithRange:NSMakeRange(currentPos, charRange.length)]];
        
        // 核心：移除已处理部分，让 layoutManager 重新从 0 坐标开始排版下一段
        [textStorage deleteCharactersInRange:NSMakeRange(0, charRange.length)];
        currentPos += charRange.length;
    }
    
    if (_pages.count == 0 && _fullText.length > 0) {
        [_pages addObject:[NSValue valueWithRange:NSMakeRange(0, _fullText.length)]];
    }
}

- (void)updateContent {
    if (_pages.count == 0) return;
    
    NSRange range = [_pages[_currentPage] rangeValue];
    NSString *sub = [_fullText substringWithRange:range];
    
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.lineSpacing = 8;
    
    NSDictionary *attr = @{
        NSFontAttributeName: [NSFont systemFontOfSize:22],
        NSForegroundColorAttributeName: [NSColor colorWithDeviceWhite:0.1 alpha:1.0],
        NSParagraphStyleAttributeName: style
    };
    
    [[_textView textStorage] setAttributedString:[[NSAttributedString alloc] initWithString:sub attributes:attr]];
    
    // 重置滚动条位置到顶部（防止翻页后停留在底部）
    [_textView scrollToBeginningOfDocument:nil];
    
    [self setTitle:[NSString stringWithFormat:@"Metal Reader - 第 %ld/%ld 页 (PgUp/PgDn 翻页)", _currentPage + 1, _pages.count]];
    [_mtkView setNeedsDisplay:YES];
}

- (void)windowDidResize:(NSNotification *)notification {
    [self paginate];
    [self updateContent];
}

// --- Metal 渲染代理 ---
- (void)drawInMTKView:(MTKView *)view {
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!drawable) return;
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:_pso];
    [enc setTexture:drawable.texture atIndex:0];
    MTLSize gridSize = MTLSizeMake(drawable.texture.width, drawable.texture.height, 1);
    NSUInteger w = _pso.threadExecutionWidth;
    NSUInteger h = _pso.maxTotalThreadsPerThreadgroup / w;
    [enc dispatchThreads:gridSize threadsPerThreadgroup:MTLSizeMake(w, h, 1)];
    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

@end

// --- 程序入口 ---
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        
        NSString *txt = @"(无内容)";
        if (argc > 1) {
            NSString *path = [NSString stringWithUTF8String:argv[1]];
            txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            if (!txt) txt = [NSString stringWithContentsOfFile:path encoding:0x80000632 error:nil];
        } else {
            txt = @"请提供 TXT 文件路径。\n\n按键盘上的 Page Up 和 Page Down 键进行翻页。";
        }
        
        ReaderWindow *win = [[ReaderWindow alloc] initWithText:txt];
        [win makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
