//   clang++ -Wall -O3 -framework Cocoa -framework ApplicationServices main.mm -o FullScreenTool
#include <iostream>
#include <CoreFoundation/CoreFoundation.h>
#include <ApplicationServices/ApplicationServices.h>
#include <Cocoa/Cocoa.h>
#include <unistd.h>

// 检查辅助功能权限
bool checkAccessibility() {
    NSDictionary *options = @{(id)kAXTrustedCheckOptionPrompt: @YES};
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

void makeAppFullScreen(pid_t pid) {
    AXUIElementRef appRef = AXUIElementCreateApplication(pid);
    if (!appRef) return;

    AXUIElementRef windowRef = NULL;
    AXError err = kAXErrorFailure;

    // 尝试获取主窗口，增加重试次数
    for (int i = 0; i < 15; i++) {
        err = AXUIElementCopyAttributeValue(appRef, kAXMainWindowAttribute, (CFTypeRef *)&windowRef);
        if (err == kAXErrorSuccess && windowRef != NULL) {
            break;
        }
        usleep(300000); // 0.3秒
    }

    if (err != kAXErrorSuccess || windowRef == NULL) {
        // 如果拿不到主窗口，尝试获取“窗口列表”中的第一个
        CFArrayRef windowList = NULL;
        AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, (CFTypeRef *)&windowList);
        if (windowList && CFArrayGetCount(windowList) > 0) {
            windowRef = (AXUIElementRef)CFArrayGetValueAtIndex(windowList, 0);
            CFRetain(windowRef);
            CFRelease(windowList);
            std::cout << "  > Using window from list instead of MainWindow" << std::endl;
        }
    }

    if (windowRef) {
        CFBooleanRef isFullScreen = kCFBooleanFalse;
        AXUIElementCopyAttributeValue(windowRef, CFSTR("AXFullScreen"), (CFTypeRef *)&isFullScreen);
        
        if (isFullScreen != kCFBooleanTrue) {
            AXError setErr = AXUIElementSetAttributeValue(windowRef, CFSTR("AXFullScreen"), kCFBooleanTrue);
            if (setErr == kAXErrorSuccess) {
                std::cout << "  [SUCCESS] PID " << pid << " set to full screen." << std::endl;
            } else {
                std::cout << "  [FAIL] Could not set full screen. Error: " << setErr << " (Maybe app doesn't support it?)" << std::endl;
            }
        } else {
            std::cout << "  [INFO] Already full screen." << std::endl;
        }
        CFRelease(windowRef);
    } else {
        std::cout << "  [FAIL] Could not find any valid window for PID " << pid << std::endl;
    }
    CFRelease(appRef);
}

@interface AppListener : NSObject
- (void)appActivated:(NSNotification *)notification;
@end

@implementation AppListener
- (void)appActivated:(NSNotification *)notification {
    NSRunningApplication *app = [[notification userInfo] objectForKey:NSWorkspaceApplicationKey];
    if (app && app.processIdentifier != [[NSProcessInfo processInfo] processIdentifier]) {
        pid_t pid = app.processIdentifier;
        std::string name = app.localizedName ? [app.localizedName UTF8String] : "Unknown";
        std::cout << "\nTarget App Activated: " << name << " (PID: " << pid << ")" << std::endl;
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            makeAppFullScreen(pid);
        });
    }
}
@end

int main() {
    @autoreleasepool {
        // 1. 启动时检查权限
        if (!checkAccessibility()) {
            std::cerr << "!!! ERROR: Accessibility permissions NOT granted." << std::endl;
            std::cerr << "Please enable it in System Settings -> Privacy & Security -> Accessibility." << std::endl;
            // 继续执行，但 API 可能失效
        }

        AppListener *listener = [[AppListener alloc] init];
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:listener
                                                               selector:@selector(appActivated:)
                                                                   name:NSWorkspaceDidActivateApplicationNotification
                                                                 object:nil];

        std::cout << ">>> Auto-FullScreen Service Running..." << std::endl;
        [[NSApplication sharedApplication] run];
    }
    return 0;
}
