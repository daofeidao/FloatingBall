#import "HUDMainWindow.h"

// 这个窗口会被注册给 SpringBoard，从而浮在所有 App 之上。
//
// ⚠️⚠️ 0.1.18 起**整体照抄 TheBall 2.7**（用户 2026-10-18 定案：
//     「我手机上那个 TheBall 点、拖、双击全没问题」）。
//
// 反汇编 TheBall 的 `HUDMainWindow`，它一共覆盖 **9 个方法**，我们以前只有 3 个：
//   +_isSystemWindow                          = YES   （我们原来就有）
//   -_isWindowServerHostingManaged            = NO    （我们原来就有）
//   -_ignoresHitTest                          = 运行时可切换（0.1.20，见下）
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

/// 0.1.26：**默认 NO**（= 吃掉触摸 / 不穿透，照 TheBall 2.7）。这是从 0.1.19 一路错到
/// 0.1.25 的根因修正 —— 完整记下来，免得再被绕回去：
///
/// **0.1.18（NO，全屏窗口）** → 真机整屏哑巴。当时同时还有两个坐标 bug：
///   `hitTest:` 漏 `convertPoint:toView:`、`FBPassThroughView.pointInside` 直接用 `.frame`
///   （都在 0.1.19 修掉）—— pointInside 对整屏返回 YES → 全屏触摸被吞。
///   **哑巴的根因是坐标 bug，不是 NO 本身。**
///
/// **0.1.19（改回 YES）** → 依据是「窗口问=0，iOS 15.1+ 不把真触摸派发给 root 窗口」。
///   **这是循环论证**：`_ignoresHitTest = YES` 本身就是「别拿我们做命中测试」，系统当然不问，
///   「窗口问=0」是这个设置的**结果**，不是系统能力的证据。0.1.20 把它做成开关但默认仍关着，
///   于是这条错误结论又延续了五版（连 0.1.25 也只修了 sLastFedPoint 拖动坐标、没翻这个窗）。
///
/// **0.1.26（默认 NO）** → 用户 2026-10-19 实测定案：「**TheBall 在我的手机上完全可以**」
///   （同机型 iPhone 13 Pro Max / iOS 15.6.1）。TheBall 的窗口就是全屏 +
///   `_ignoresHitTest = NO` + 那 9 个覆写，它吃系统真触摸、点/拖/双击全正常、不穿透。
///   我们这 9 个覆写和全屏窗口都和它一致，0.1.19 起坐标 bug 也修了 —— 没有理由再绕开这条路。
///
/// 三种可能的结果，都不比现在差：
///   ① 系统派发真触摸（TheBall 同款）→ 点/拖/双击全走真触摸，不穿透，合成自动停；
///   ② 系统做命中测试但不派发 → 球内那一下被我们吃掉（不漏给下面），球照常动作
///      （合成那条路不看这个设置），只是拖动仍靠合成坐标；
///   ③ 系统完全无视我们 → 和开关关着一样（穿透 + 合成），零变化。
///
/// 带 1 秒缓存：这是命中测试热路径，不能每次调用都读一次盘。
/// 用户改完设置，球在 1 秒内自动生效，不用重启球。
- (BOOL)_ignoresHitTest
{
    static NSTimeInterval lastAt = 0;
    // ⚠️ 默认值语义（0.1.26 起）：**键不存在 = 吃掉（NO）**。
    //    只有用户显式写过 false（=「我要穿透」）才返回 YES。
    static BOOL lastValue = NO;
    NSTimeInterval now = CACurrentMediaTime();
    if (now - lastAt > 1.0) {
        lastAt = now;
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:USER_DEFAULTS_PATH];
        id v = d[@"SwallowTouch"];
        lastValue = (v && ![v boolValue]) ? YES : NO;
    }
    return lastValue;
}

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
