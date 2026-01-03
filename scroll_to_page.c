#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>

// 定义 Page Up 和 Page Down 的虚拟键码
#define kVK_PageUp   (0x74)
#define kVK_PageDown (0x79)

// 模拟发送键盘事件
void post_key(CGKeyCode key) {
    // 创建按下事件
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, key, true);
    // 创建抬起事件
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, key, false);
    
    // 发送事件
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    
    CFRelease(down);
    CFRelease(up);
}

// 事件回调函数
CGEventRef myCallBack(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    if (type == kCGEventScrollWheel) {
        // 获取滚动方向
        // FixedPoint 数值，正数向上，负数向下
        int64_t delta = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);

        if (delta > 0) {
            // 向上滚 -> 模拟 Page Up
            post_key(kVK_PageUp);
            return NULL; // 拦截事件，不让系统继续处理原始滚动
        } else if (delta < 0) {
            // 向下滚 -> 模拟 Page Down
            post_key(kVK_PageDown);
            return NULL; // 拦截事件
        }
    }
    return event;
}

int main() {
    // 监听鼠标滚轮事件
    CGEventMask eventMask = CGEventMaskBit(kCGEventScrollWheel);

    // 参数说明：
    // kCGHIDEventTap: 从 HID 层拦截
    // kCGHeadInsertEventTap: 插入到事件处理链的最头部
    // kCGEventTapOptionDefault: 活动模式（可以拦截并修改事件）
    CFMachPortRef eventTap = CGEventTapCreate(
        kCGHIDEventTap, 
        kCGHeadInsertEventTap, 
        kCGEventTapOptionDefault, 
        eventMask, 
        myCallBack, 
        NULL
    );

    if (!eventTap) {
        fprintf(stderr, "错误: 无法创建事件钩子。请确保在“系统设置 -> 隐私与安全性 -> 辅助功能”中允许了终端程序。\n");
        return 1;
    }

    // 创建运行循环
    CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
    CGEventTapEnable(eventTap, true);
    
    printf("程序启动成功！现在滚动鼠标滚轮将触发 PageUp/PageDown。\n");
    printf("按 Ctrl+C 退出程序。\n");
    
    CFRunLoopRun();

    return 0;
}
