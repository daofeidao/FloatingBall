#import <Foundation/Foundation.h>

#pragma mark - HUD 进程开关

OBJC_EXTERN BOOL IsHUDEnabledBridger(void);
OBJC_EXTERN void SetHUDEnabledBridger(BOOL isEnabled);
OBJC_EXTERN void waitForNotificationBridger(void (^onFinish)(), BOOL isEnabled);

#pragma mark - 让 HUD 重新读设置

/// 跨进程发一个 Darwin 通知（HUD 那边用 notify_register_dispatch 收）
OBJC_EXTERN void FBPostNotify(const char *name);

/// 通知名（和 hud-prefix.pch 里那几条保持一致）
OBJC_EXTERN NSString *const FBNotifyReloadHUD;
