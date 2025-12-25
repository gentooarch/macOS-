//clang -fobjc-arc -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore main.m -o MetalReader
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
    NSUInteger masks = NSWindowStyleMaskTitled | NSWindowStyleMaskResizable | 
                       NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | 
                       NSWindowStyleMaskFullSizeContentView;
    
    self = [super initWithContentRect:NSMakeRect(0, 0, 1000, 800)
                            styleMask:masks
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (self) {
        _fullText = (text && text.length > 0) ? text : @"(无内容)";
        _currentPage = 0;
        _pages = [NSMutableArray new];
        _device = MTLCreateSystemDefaultDevice();
        _queue = [_device newCommandQueue];
        
        // --- 核心：绝对禁止磁盘写入 ---
        [self setRestorable:NO];                   // 禁用窗口恢复
        [self setIdentifier:nil];                  // 禁用偏好关联
        [self setAnimationBehavior:NSWindowAnimationBehaviorNone]; // 禁用动画缓存
        
        [self setupMetal];
        [self setupUI];
        
        [self setDelegate:self];
        [self setBackgroundColor:[NSColor blackColor]];
        [self setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary]; 
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
    [_textView setTextContainerInset:NSMakeSize(80, 60)]; 
    
    // 禁用所有可能触发缓存的功能
    [_textView setContinuousSpellCheckingEnabled:NO];
    [_textView setAutomaticQuoteSubstitutionEnabled:NO];
    [_textView setAutomaticDashSubstitutionEnabled:NO];
    [_textView setAutomaticSpellingCorrectionEnabled:NO];
    
    _textView.textContainer.lineFragmentPadding = 0;
    
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

// 拦截按键：仅保留 PgUp(116) / PgDn(121) / ESC(53)
- (void)sendEvent:(NSEvent *)event {
    if (event.type == NSEventTypeKeyDown) {
        if (event.keyCode == 121) { 
            if (_currentPage < _pages.count - 1) {
                _currentPage++;
                [self updateContent];
            }
            return;
        } else if (event.keyCode == 116) { 
            if (_currentPage > 0) {
                _currentPage--;
                [self updateContent];
            }
            return;
        } else if (event.keyCode == 53) { 
            [NSApp terminate:nil];
            return;
        }
    }
    [super sendEvent:event];
}

// 精确分页逻辑
- (void)paginate {
    [_pages removeAllObjects];
    
    NSSize containerSize = _textView.bounds.size;
    if (containerSize.width <= 0 || containerSize.height <= 0) return;

    CGFloat insetWidth = _textView.textContainerInset.width * 2;
    CGFloat insetHeight = _textView.textContainerInset.height * 2;
    NSSize renderSize = NSMakeSize(containerSize.width - insetWidth, containerSize.height - insetHeight);

    NSDictionary *attrs = @{ 
        NSFontAttributeName: [NSFont systemFontOfSize:24], 
        NSParagraphStyleAttributeName: [self paragraphStyle]
    };

    NSTextStorage *textStorage = [[NSTextStorage alloc] initWithString:_fullText];
    [textStorage setAttributes:attrs range:NSMakeRange(0, textStorage.length)];
    
    NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
    NSTextContainer *textContainer = [[NSTextContainer alloc] initWithSize:renderSize];
    textContainer.lineFragmentPadding = 0;
    
    [layoutManager addTextContainer:textContainer];
    [textStorage addLayoutManager:layoutManager];

    NSUInteger currentPos = 0;
    NSUInteger totalLen = _fullText.length;

    while (currentPos < totalLen) {
        [layoutManager ensureLayoutForTextContainer:textContainer];
        NSRange glyphRange = [layoutManager glyphRangeForBoundingRect:NSMakeRect(0, 0, renderSize.width, renderSize.height)
                                                      inTextContainer:textContainer];
        // --- 此处修正：characterRangeForGlyphRange ---
        NSRange charRange = [layoutManager characterRangeForGlyphRange:glyphRange actualGlyphRange:NULL];
        
        if (charRange.length == 0) break;
        [_pages addObject:[NSValue valueWithRange:NSMakeRange(currentPos, charRange.length)]];
        [textStorage deleteCharactersInRange:NSMakeRange(0, charRange.length)];
        currentPos += charRange.length;
    }
    
    if (_pages.count == 0 && _fullText.length > 0) {
        [_pages addObject:[NSValue valueWithRange:NSMakeRange(0, _fullText.length)]];
    }
}

- (NSParagraphStyle *)paragraphStyle {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.lineSpacing = 10;
    style.paragraphSpacing = 15;
    return style;
}

- (void)updateContent {
    if (_pages.count == 0) return;
    if (_currentPage >= _pages.count) _currentPage = _pages.count - 1;

    NSRange range = [_pages[_currentPage] rangeValue];
    NSString *sub = [_fullText substringWithRange:range];
    
    NSDictionary *attr = @{
        NSFontAttributeName: [NSFont systemFontOfSize:24],
        NSForegroundColorAttributeName: [NSColor colorWithDeviceWhite:0.1 alpha:1.0],
        NSParagraphStyleAttributeName: [self paragraphStyle]
    };
    
    [[_textView textStorage] setAttributedString:[[NSAttributedString alloc] initWithString:sub attributes:attr]];
    [_textView scrollToBeginningOfDocument:nil];
    [_mtkView setNeedsDisplay:YES];
}

// 全屏状态改变后的处理
- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    [self paginate];
    [self updateContent];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
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

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        
        // 禁用 macOS 的窗口状态持久化
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"NSQuitAlwaysKeepsWindows"];

        NSString *txt = @"(无内容)";
        if (argc > 1) {
            NSString *path = [NSString stringWithUTF8String:argv[1]];
            txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            if (!txt) txt = [NSString stringWithContentsOfFile:path encoding:0x80000632 error:nil];
        }
        
        ReaderWindow *win = [[ReaderWindow alloc] initWithText:txt];
        [win makeKeyAndOrderFront:nil];
        
        // 立即全屏
        [win toggleFullScreen:nil];
        
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
