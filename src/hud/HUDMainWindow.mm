#import "HUDMainWindow.h"

// 这个窗口会被注册给 SpringBoard，从而浮在所有 App 之上。
//
// ⚠️⚠️ 0.1.18 起**整体照抄 TheBall 2.7**（用户 2026-10-18 定案：
//     「我手机上那个 TheBall 点、拖、双击全没问题」）。
//
// 反汇编 TheBall 的 `HUDMainWindow`，它一共覆盖 **9 个方法**，我们以前只有 3 个：
//   +_isSystemWindow                          = YES   （我们原来就有）
//   -_isWindowServerHostingManaged            = NO    （我们原来就有）
//   -_ignoresHitTest                          = NO    （见下面，0.1.19 改回 YES）
//   -_isSecure                                = YES   ← 我们缺
//   -_shouldCreateContextAsSecure             = YES   ← 我们缺
//   -_shouldAutorotateToInterfaceOrientation: = YES   ← 我们缺
//   -supportedInterfaceOrientations           = All   ← 我们缺
//   -shouldAutorotate                         = YES   ← 我们缺
//   -hitTest:withEvent:                       = 只交给子视图，别的一律 nil ← 我们缺
//
// 另外（同一处反汇编）：TheBall 的窗口用 **[UIScreen mainScreen].bounds 全屏**创建，
// 球是窗口里的一个子视图；我们以前把窗口做成「只有球那么大」——
// 那正是「触摸永远进不来」的根源之一。
//
// ⚠️⚠️ 0.1.19：**只照抄窗口的「样子」，不照抄它的命中测试策略。**
//
// TheBall 的触摸是**系统真触摸**（它直接写 touchesBegan/Moved/Ended，拿的是 SpringBoard
// 派发进来的真事件），所以它把 `_ignoresHitTest` 设成 NO、让系统来命中。
// 我们不是那条路 —— 我们的触摸全部是**自己从 HID 事件合成的**
// （HUDApp.mm → TSEventFetcher → `[app sendEvent:]`）。
//
// 0.1.18 把窗口改成全屏、又留着 `_ignoresHitTest = NO`，于是：
//   SpringBoard 看到「有一个全屏的、level 最高的系统窗口」，会把**整块屏幕**的命中测试
//   判给它；但 iOS 15.1+ 系统又不会把真触摸派发进我们这个 root 进程的窗口
//   （这条在 0.1.8~0.1.17 的自检里是硬证据：「窗口问=0」）——
//   **结果就是整块屏幕的触摸被这个窗口吃掉，谁都收不到**。
//   那是比「球点不动」严重得多的故障（手机整个变成哑巴，只能强制重启）。
//
// 所以 `_ignoresHitTest` 必须回到 **YES**（Helium / TrollSpeed 的原值，二者都在生产用）：
//   · SpringBoard 完全不把这个窗口当命中目标 → 触摸原样漏给下面的 App；
//   · 我们自己合成触摸走的是 `[app sendEvent:]`，**根本不看 `_ignoresHitTest`**，
//     所以合成路线一点不受影响（Helium 就是这么跑的）；
//   · `windowLevel` 保持最高 → 窗口照样浮在所有 App 之上。
//
// ⚠️ 安全阀仍然在这两层（缺一不可）：
//   ① 本类的 hitTest: 遍历子视图，**没有一个命中就返回 nil**（触摸漏给下面的 App）；
//   ② 根视图是 FBPassThroughView，球以外一律返回 NO。
// 这两层是「万一吞掉整屏触摸」的最后保险，别动。
@implementation HUDMainWindow

+ (BOOL)_isSystemWindow { return YES; }

- (BOOL)_isWindowServerHostingManaged { return NO; }

/// 0.1.19：由 NO 改回 **YES**（Helium / TrollSpeed 原值）。理由见文件顶部那一段：
/// 我们不吃系统派发的真触摸，全屏窗口 + NO 会让 SpringBoard 把整屏触摸判给这个
/// 窗口又送不进来 —— 手机直接变成哑巴。合成路线不走这里，改成 YES 反而是修 bug。
- (BOOL)_ignoresHitTest { return YES; }

- (BOOL)_isSecure { return YES; }

- (BOOL)_shouldCreateContextAsSecure { return YES; }

- (BOOL)_shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation { return YES; }

- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

- (BOOL)shouldAutorotate { return YES; }

/// 照抄 TheBall：只把命中测试交给子视图；子视图都不认，就返回 nil（漏给下面）。
///
/// ⚠️ 0.1.19 修坐标转换：`point` 是**本窗口**的坐标，`sub` 的坐标系未必等于窗口
///    （根视图的 frame 一旦被 UIKit 挪过 —— 安全区、旋转、`bounds.origin` 非 0 ——
//    命中就会整体偏移，表现为「球明明在那儿却点不到」）。
///    必须先 `[self convertPoint:point toView:sub]` 换到子视图的坐标系。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    for (UIView *sub in self.subviews) {
        UIView *hit = [sub hitTest:[self convertPoint:point toView:sub] withEvent:event];
        if (hit) return hit;
    }
    return nil;
}

@end
