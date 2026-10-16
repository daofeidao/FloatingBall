//
//  SwiftObjCPPBridger.m
//
//  Swift 够不着的 ObjC/C 函数，从这里过一手。
//

#import "SwiftObjCPPBridger.h"
#import <notify.h>

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
