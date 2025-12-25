//clang -fobjc-arc -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore main.m -o MetalReader
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

// --- Metal 着色器 ---
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
        [self setTitle:@"Metal Reader"];
        [self setTitlebarAppearsTransparent:YES];
        [self center];
        
        // 关键：确保窗口可以成为关键窗口以接收键盘事件
        [self setReleasedWhenClosed:NO];
    }
    return self;
}

// 拦截所有键盘事件，确保翻页逻辑最高优先级
- (void)sendEvent:(NSEvent *)event {
    if (event.type == NSEventTypeKeyDown) {
        // 124: Right, 49: Space, 123: Left
        if (event.keyCode == 124 || event.keyCode == 49) {
            [self nextPage];
            return; // 拦截，不传给 NSTextView
        } else if (event.keyCode == 123) {
            [self prevPage];
            return;
        } else if (event.keyCode == 53) { // ESC
            [NSApp terminate:nil];
            return;
        }
    }
    [super sendEvent:event];
}

- (void)nextPage {
    if (_currentPage < _pages.count - 1) {
        _currentPage++;
        [self updateContent];
    }
}

- (void)prevPage {
    if (_currentPage > 0) {
        _currentPage--;
        [self updateContent];
    }
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
    
    _textView = [[NSTextView alloc] initWithFrame:scroll.bounds];
    [_textView setEditable:NO];
    [_textView setSelectable:YES];
    [_textView setBackgroundColor:[NSColor clearColor]];
    [_textView setTextContainerInset:NSMakeSize(60, 50)];
    
    // 强制不显示滚动条，避免干扰
    [scroll setHasVerticalScroller:NO];
    [scroll setHasHorizontalScroller:NO];

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

// 在窗口显示后触发分页，确保获取的尺寸是真实的
- (void)becomeKeyWindow {
    [super becomeKeyWindow];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self paginate];
        [self updateContent];
    });
}

- (void)paginate {
    [_pages removeAllObjects];
    
    // 获取文字显示区的实际尺寸（窗口大小减去 Inset）
    NSSize windowSize = self.frame.size;
    CGFloat insetW = _textView.textContainerInset.width * 2;
    CGFloat insetH = _textView.textContainerInset.height * 2;
    NSSize renderSize = NSMakeSize(windowSize.width - insetW, windowSize.height - insetH);

    NSTextStorage *textStorage = [[NSTextStorage alloc] initWithString:_fullText];
    NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
    NSTextContainer *textContainer = [[NSTextContainer alloc] initWithSize:renderSize];
    
    [layoutManager addTextContainer:textContainer];
    [textStorage addLayoutManager:layoutManager];
    
    NSDictionary *attrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:22] };
    [textStorage setAttributes:attrs range:NSMakeRange(0, textStorage.length)];

    NSUInteger totalLength = _fullText.length;
    NSUInteger currentPos = 0;

    while (currentPos < totalLength) {
        // 强制布局
        [layoutManager ensureLayoutForTextContainer:textContainer];
        
        NSRange glyphRange = [layoutManager glyphRangeForBoundingRect:NSMakeRect(0, 0, renderSize.width, renderSize.height)
                                                      inTextContainer:textContainer];
        NSRange charRange = [layoutManager characterRangeForGlyphRange:glyphRange actualGlyphRange:NULL];
        
        if (charRange.length == 0) break;

        [_pages addObject:[NSValue valueWithRange:NSMakeRange(currentPos, charRange.length)]];
        
        // 移除已经分页的部分，继续计算
        [textStorage deleteCharactersInRange:NSMakeRange(0, charRange.length)];
        currentPos += charRange.length;
    }
    
    // 如果没有分出页（比如文本极短），手动加一页
    if (_pages.count == 0 && _fullText.length > 0) {
        [_pages addObject:[NSValue valueWithRange:NSMakeRange(0, _fullText.length)]];
    }
}

- (void)updateContent {
    if (_pages.count == 0) return;
    if (_currentPage >= _pages.count) _currentPage = _pages.count - 1;

    NSRange range = [_pages[_currentPage] rangeValue];
    NSString *sub = [_fullText substringWithRange:range];
    
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.lineSpacing = 10;
    
    NSDictionary *attr = @{
        NSFontAttributeName: [NSFont systemFontOfSize:22],
        NSForegroundColorAttributeName: [NSColor colorWithDeviceWhite:0.1 alpha:1.0],
        NSParagraphStyleAttributeName: style
    };
    
    [[_textView textStorage] setAttributedString:[[NSAttributedString alloc] initWithString:sub attributes:attr]];
    
    // 更新进度显示
    [self setTitle:[NSString stringWithFormat:@"Metal Reader - 第 %ld/%ld 页", _currentPage + 1, _pages.count]];
    [_mtkView setNeedsDisplay:YES];
}

// 窗口尺寸改变时，需要重新分页
- (void)windowDidResize:(NSNotification *)notification {
    [self paginate];
    [self updateContent];
}

// --- Metal 渲染部分 (保持不变) ---
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
        
        NSString *txt = @"(无内容)";
        if (argc > 1) {
            NSString *path = [NSString stringWithUTF8String:argv[1]];
            txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            if (!txt) { // 尝试 GBK
                txt = [NSString stringWithContentsOfFile:path encoding:0x80000632 error:nil];
            }
        } else {
            txt = @"请在终端运行并拖入一个 txt 文件。\n例如: ./MetalReader book.txt\n\n快捷键: 空格/右键翻页, 左键往回翻。";
        }
        
        ReaderWindow *win = [[ReaderWindow alloc] initWithText:txt];
        [win makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
