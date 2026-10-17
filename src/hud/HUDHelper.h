#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>   // FBHUDSetBallView 的参数是 UIView

NS_ASSUME_NONNULL_BEGIN

OBJC_EXTERN BOOL IsHUDEnabled(void);
OBJC_EXTERN void SetHUDEnabled(BOOL isEnabled);
OBJC_EXTERN void waitForNotification(void (^onFinish)(), BOOL isEnabled);

/// 把「屏幕上的那个球」交给 HUD 的触摸回调。
/// 触摸走的是「全局 HID 事件 → 自己喂给球视图」那条路（见 HUDApp.mm），
/// 回调要靠这个视图算「这一下是不是按在球上」。
/// 在 BallRootViewController 的 viewDidLoad 里调用。
OBJC_EXTERN void FBHUDSetBallView(UIView *ballView);

// ---- 触摸自检（0.1.8）----
// 0.1.8 把窗口的 _ignoresHitTest 改回 NO（参考 TheBall），于是「系统直接把触摸
// 送进窗口」这条路重新成立。下面三个函数用来判断它到底通了没有 ——
// 光看「点球没反应」分不出是「没送进来」还是「送进来了手势不认」。
//
// 读法（自检里那行「真触摸：窗口问=N 落在球=N 真点击=N」）：
//   窗口问=0            → 触摸压根没送进这个窗口
//   窗口问>0 落在球=0    → 送进来了，但没落在球上（球位置 / 坐标系对不上）
//   落在球>0 真点击=0    → 落到球上了，手势却没认出来（手势本身的问题）

/// 系统在命中测试里问「这个点是不是你的」（由 FBPassThroughView 调）。
OBJC_EXTERN void FBProbeTouchHit(BOOL onBall);

/// 球自己的单击手势真的触发了（由 BallRootViewController 调）。
OBJC_EXTERN void FBProbeRealTapDidFire(void);

/// 真触摸这条路通了没有（通了就不再喂合成的假触摸，免得一次点击走两遍）。
OBJC_EXTERN BOOL FBRealTouchWorks(void);

NS_ASSUME_NONNULL_END