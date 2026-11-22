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

/// 0.1.47：列出某个 App 在 Info.plist 里声明的 URL schemes
/// （`CFBundleURLTypes` → `CFBundleURLSchemes`，顺序保持不变、去重）。
/// 没声明就返回空数组。
OBJC_EXTERN NSArray<NSString *> *FBAppURLSchemes(NSString *bundleID);

/// 打开任意 App（和悬浮球进程里那条是同一份实现）
OBJC_EXTERN BOOL FBOpenApplication(NSString *bundleID);

/// 打开任意 URL（URL 协议 / 系统快捷指令都走这条）：
/// 微信扫一扫 weixin://scanqrcode、微信收付款 weixin://widget/pay、
/// 支付宝扫一扫 alipayqr://platformapi/startapp?saId=10000007、
/// 系统快捷指令 shortcuts://run-shortcut?name=<名字>
/// ⚠️ 返回 YES 只代表「系统收下了这个请求」，不代表对面真的执行了。
OBJC_EXTERN BOOL FBOpenURL(NSString *urlString);

/// 刷新蜂窝网络信号（卡贴机没信号 / 假信号时点一下）
/// ⚠️ 没有结果可看：这个 API 只是把请求交给 CommCenter，成没成只能看状态栏
OBJC_EXTERN BOOL FBRefreshCellularSignal(void);

#pragma mark - 0.1.47：脚本 / 桌面快捷方式

/// 跑一段 shell 脚本（`/bin/sh`，以 **root** 身份）。
/// - Returns: @{ @"status": NSNumber 退出码, @"output": NSString（stdout+stderr 合并，最多 8KB） }
/// ⚠️ 超时 15 秒会强杀整个进程组。
OBJC_EXTERN NSDictionary<NSString *, id> *FBRunShellScript(NSString *code);

/// 把一条 URL 写成桌面图标（webclip）。
/// 写的是 `/var/mobile/Library/WebClips/<UUID>.webclip/{Info.plist, icon.png}` ——
/// 和 Safari「添加到主屏幕」同一套格式；写完需要 respring 才会出现。
/// - Returns: @{ @"ok": NSNumber, @"path": NSString, @"error": NSString }
OBJC_EXTERN NSDictionary<NSString *, id> *FBAddWebClipToHomeScreen(NSString *title,
                                                                  NSString *url,
                                                                  NSString *symbolName);

/// 重启 SpringBoard（respring）。返回有没有把 killall 发出去。
/// ⚠️ 会杀掉本 App 自己；球进程能活下来并自动重建。
OBJC_EXTERN BOOL FBRespringSpringBoard(void);

/// 【截屏】两条路：先试系统自己的截图服务（不注入输入，最安全），
/// 取不到再注入一次「音量加 + 电源」组合键（iOS 的截图快捷键）。
/// - Returns: 实际走的哪条路：0 = 都没走通，1 = 系统截图服务，2 = 按键注入。
///            细节写在 /tmp/FloatingBall.log 里。
OBJC_EXTERN int FBTakeScreenshot(void);
