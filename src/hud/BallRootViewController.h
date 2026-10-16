#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 悬浮球的视图控制器。它是 HUD 进程（root）里那个全局窗口的根控制器。
@interface BallRootViewController : UIViewController

/// 窗口边长 = 球直径 + 余量（余量给阴影和手指宽容区）
- (CGFloat)windowSide;

/// 球心初始位置（读上次保存的，没有就给个默认）
- (CGPoint)initialCenter;

/// 重新读一遍共享设置（被 Darwin 通知触发）
- (void)reloadSettings;

@end

NS_ASSUME_NONNULL_END
