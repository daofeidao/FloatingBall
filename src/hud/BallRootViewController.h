#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 悬浮球的视图控制器。它是 HUD 进程（root）里那个全局窗口的根控制器。
@interface BallRootViewController : UIViewController

/// 窗口边长 = 球直径 + 余量（余量给阴影和手指宽容区）
- (CGFloat)windowSide;

/// 球直径
- (CGFloat)ballSize;

/// 球心初始位置（读上次保存的，没有就给个默认）
- (CGPoint)initialCenter;

/// 重新读一遍共享设置（被 Darwin 通知触发）
- (void)reloadSettings;

/// 按下去的**可见**反馈：球缩一下再弹回（0.1.16）。
/// 为什么要有它：HUD 是后台进程，`UIImpactFeedbackGenerator` 的震动会被系统吞掉，
/// 缩放只是改 transform，不依赖系统服务 —— 至少让用户看见「按到了」。
- (void)pressFeedback;

@end

NS_ASSUME_NONNULL_END
