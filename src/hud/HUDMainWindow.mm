#import "HUDMainWindow.h"

// 这个窗口会被注册到 SpringBoard，从而浮在所有 App 之上。
//
// ⚠️ 2026-10-17 真机结论（改过一次，别再改回去）：
//   一开始认为「这个窗口要能被点中」，所以 _ignoresHitTest 返回 NO。
//   真机结果：**返回 NO 也一样收不到触摸** —— SpringBoard 托管的这个窗口
//   只负责显示，系统根本不会把触摸送进来（点球时数字一个都不涨）。
//   所以触摸改走另一条路：自己监听全局 HID 事件、手动喂给球视图
//   （见 HUDApp.mm 的 _HUDEventCallback）。这里就回到和 Helium 一样的 YES：
//   窗口**绝不参与命中测试** —— 少一层「万一吞掉整屏触摸」的风险。
//
// ⚠️ 窗口尺寸仍然必须**只有球那么大**（见 HUDMainApplicationDelegate）：
//    万一以后有人把这条路又改回去，尺寸是最后一道保险。
@implementation HUDMainWindow

+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return YES; }

@end
