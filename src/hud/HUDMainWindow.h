#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HUDMainWindow : UIWindow

/// 0.1.27：是否「穿透」（系统不把真触摸派发给球，靠合成兜底）。
/// 键不存在 / SwallowTouch = true → NO（吃掉 / 不穿透，系统派发真触摸）；
/// SwallowTouch = false            → YES（穿透）。
+ (BOOL)fb_passThrough;

@end

NS_ASSUME_NONNULL_END