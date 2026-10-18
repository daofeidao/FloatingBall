#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>   // FBHUDSetBallView 的参数是 UIView

NS_ASSUME_NONNULL_BEGIN

OBJC_EXTERN BOOL IsHUDEnabled(void);
OBJC_EXTERN void SetHUDEnabled(BOOL isEnabled);
OBJC_EXTERN void waitForNotification(void (^onFinish)(), BOOL isEnabled);

/// 球进程的 pid 文件路径 —— **App 和球共用的那一份**（`/tmp/FloatingBall.hud.pid`）。
/// 0.1.11 起它同时是「球在不在跑」的唯一判据：球启动时写，退出/被杀时删，
/// App 侧读出来 + kill(pid,0) 就能秒判，不用再 spawn 一个 -check 进程（那是开关慢的根因）。
OBJC_EXTERN NSString *FBHUDPIDFilePath(void);

/// 把「屏幕上的那个球」交给 HUD 的触摸回调。
/// 触摸走的是「全局 HID 事件 → 自己喂给球视图」那条路（见 HUDApp.mm），
/// 回调要靠这个视图算「这一下是不是按在球上」。
/// 在 BallRootViewController 的 viewDidLoad 里调用。
OBJC_EXTERN void FBHUDSetBallView(UIView *ballView);

// ---- 触摸自检 ----
// 我们**不吃**系统派发的真触摸（iOS 15.1+ 系统不会把真触摸派发进 root 进程的窗口，
// 0.1.8~0.1.17 的自检「窗口问=0」是硬证据）。触摸全部由我们自己从 HID 事件合成
// （HUDApp.mm → TSEventFetcher → `[app sendEvent:]`）。
//
// ⚠️ 0.1.19 更正读法：
//   窗口问=0     → **正常**。_ignoresHitTest=YES（Helium 原值），系统刻意不拿我们
//                  这个全屏窗口做命中测试，触摸原样漏给下面的 App。
//   窗口问>0     → 窗口配置有变化，值得看一眼是谁在问。
//   真点击=N     → 球的手势一共触发了几次（不区分触摸来源，见下）。

/// 系统在命中测试里问「这个点是不是你的」（由 FBPassThroughView 调）。
OBJC_EXTERN void FBProbeTouchHit(BOOL onBall);

/// 球自己的单击手势触发了（由 BallRootViewController 调）。
/// ⚠️ **不区分触摸来源** —— 合成的也算。0.1.19 之前把它当成「系统派发触摸」的证据
///    是错的（见下面 FBRealTouchWorks）。
OBJC_EXTERN void FBProbeRealTapDidFire(void);

// ---- 自喂测试（0.1.14）----
// 目的：把「检测层」和「喂球层」分开。绕过 HID，直接往球心喂一次按下+抬起：
//   · 球有反应 / 自检「真点击」+1 → 喂球这条路是通的，毛病在检测层
//   · 完全没反应                 → 喂球这条路本身不通
// 测试期间球只记账、不执行绑定动作（gFBSelfTestTapPending）。
OBJC_EXTERN void FBSelfTestFeedTap(void);
OBJC_EXTERN int  FBProbeRealTapCount(void);
OBJC_EXTERN BOOL gFBSelfTestTapPending;
OBJC_EXTERN BOOL gFBBlindFeed;

/// 真触摸这条路通了没有（通了就不再喂合成的假触摸，免得一次点击走两遍）。
///
/// ⚠️⚠️ 0.1.19 修「自熔断」—— 这是「只有第一下有用」「点不动」的正主：
///    0.1.8~0.1.18 的判据是 `sProbeRealTap > 0`，而那个数是在 onSingleTap 里加的，
///    **onSingleTap 同样会被我们自己合成的触摸触发**。于是第一次点球成功就
///    把「系统真触摸通了」这个结论坐实 → HUDApp 不再喂合成触摸 → 球彻底死掉。
///    现在必须同时满足：手势触发过 **且** 系统自己问过命中测试 **且** 都在 2 秒内。
OBJC_EXTERN BOOL FBRealTouchWorks(void);

/// 球「按下」了（0.1.12 新增）：在 HUDApp.mm 的「起手在球上」那一刻调。
/// 球那边据此立刻震一下 —— 反馈要跟手指同步，不能等手势判完（有时根本判不出来）。
OBJC_EXTERN void FBBallHapticTouchDown(void);

NS_ASSUME_NONNULL_END