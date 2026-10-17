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

#pragma mark - 系统级动作（实现见 hud/FBSystemActions.mm）

/// 列出这台机器上已安装的 App，给「添加快捷方式」的选择器用。
/// 返回：@[ @{ @"id": bundleID, @"name": 显示名 } ]，按名字排好序。
OBJC_EXTERN NSArray<NSDictionary<NSString *, NSString *> *> *FBInstalledApps(void);

/// 打开任意 App（和悬浮球进程里那条是同一份实现）
OBJC_EXTERN BOOL FBOpenApplication(NSString *bundleID);

/// 刷新蜂窝网络信号（卡贴机没信号 / 假信号时点一下）
/// ⚠️ 没有结果可看：这个 API 只是把请求交给 CommCenter，成没成只能看状态栏
OBJC_EXTERN BOOL FBRefreshCellularSignal(void);

/// 【截屏】两条路：先试系统自己的截图服务（不注入输入，最安全），
/// 取不到再注入一次「音量加 + 电源」组合键（iOS 的截图快捷键）。
/// - Returns: 实际走的哪条路：0 = 都没走通，1 = 系统截图服务，2 = 按键注入。
///            细节写在 /tmp/FloatingBall.log 里。
OBJC_EXTERN int FBTakeScreenshot(void);
