#import "HUDMainWindow.h"

// 这个窗口会被注册到 SpringBoard，从而浮在所有 App 之上。
//
// ⚠️ 2026-10-17 第三版结论（逐条反汇编 TheBall 2.7 得出的，别再往回改）：
//   前两版都判错了，错在**没把球自己的手势算进去**：
//     ① 一开始想「窗口要能被点中」→ _ignoresHitTest 返回 NO，
//        真机点球没反应 → 就断定「这条路不成立」，改回 YES，去走全局 HID 事件。
//        可那时候球上根本没有手势识别器：触摸就算送进窗口，也没人接。
//        「没人接」被误读成了「收不到触摸」。
//
//   对着 TheBall 2.7 的二进制比过（同机型、同权限、它的球确实可点可拖）：
//     · -_ignoresHitTest                = NO    ← 差的就是这一条（我们原来是 YES）
//     · -_isWindowServerHostingManaged  = NO    （这一条我们一直是 NO，对的）
//     · +_isSystemWindow                = YES   （这一条我们一直是 YES，对的）
//     · 它还覆盖了 _isSecure / _shouldCreateContextAsSecure = YES，
//       以及 _shouldAutorotate / supportedInterfaceOrientations（全方向）。
//       那几条跟「摸到没摸到」无关，先不抄 —— 一次只改一条，出问题好定位。
//
//   结论：窗口注册给 SpringBoard 之后，**窗口自己也得参与命中测试**，
//   系统才会把「落在球上的触摸」送进这个进程，球的手势识别器才可能接住。
//
// ⚠️ 窗口尺寸仍然必须**只有球那么大**（见 HUDMainApplicationDelegate），
//    而且根视图是 FBPassThroughView：球以外一律返回 NO、漏给下面的 App。
//    这两层是「万一吞掉整屏触摸」的安全阀，别动。
@implementation HUDMainWindow

+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return NO; }

@end
