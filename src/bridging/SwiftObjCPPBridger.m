//
//  SwiftObjCPPBridger.m
//
//  Swift 够不着的 ObjC/C 函数，从这里过一手。
//

#import "SwiftObjCPPBridger.h"
#import <notify.h>
#import "../hud/FBLog.h"

#pragma mark - HUD Functions

extern BOOL IsHUDEnabled(void);
extern void SetHUDEnabled(BOOL isEnabled);
extern void waitForNotification(void (^onFinish)(), BOOL isEnabled);

BOOL IsHUDEnabledBridger(void)
{
    return IsHUDEnabled();
}

void SetHUDEnabledBridger(BOOL isEnabled)
{
    // 每次「开球」都重开一份日志：这一次尝试的全过程才是我们要看的
    if (isEnabled) {
        FBLogReset();
        FBLog(@"=== App 请求启动悬浮球 ===");
    } else {
        FBLog(@"=== App 请求关闭悬浮球 ===");
    }

    SetHUDEnabled(isEnabled);
}

void waitForNotificationBridger(void (^onFinish)(), BOOL isEnabled)
{
    waitForNotification(onFinish, isEnabled);
}

#pragma mark - Notifications

void FBPostNotify(const char *name)
{
    if (name) notify_post(name);
}

// 与 hud-prefix.pch 的 NOTIFY_RELOAD_HUD 保持一致
NSString *const FBNotifyReloadHUD = @NOTIFY_RELOAD_HUD;
