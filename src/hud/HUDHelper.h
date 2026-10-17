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

NS_ASSUME_NONNULL_END