#import "HUDMainWindow.h"

// 这个窗口会被注册到 SpringBoard，从而浮在所有 App 之上。
//
// 与 Helium 的关键区别：
//   Helium 的状态栏小部件「不参与命中测试」(_ignoresHitTest -> YES)，
//   所以它显示归显示、永远不会挡住别人的触摸。
//   悬浮球恰恰相反，它必须能被点中、能拖 —— 所以这里返回 NO。
//
// ⚠️ 因此窗口尺寸必须**只有球那么大**（见 HUDMainApplicationDelegate），
//    否则整屏触摸都会被这个进程吃掉，手机就没法用了。

@implementation HUDMainWindow

+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return NO; }

@end
