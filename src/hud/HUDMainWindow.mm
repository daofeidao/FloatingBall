#import "HUDMainWindow.h"

// 这个窗口会被注册给 SpringBoard，从而浮在所有 App 之上。
//
// ⚠️⚠️ 0.1.18 起**整体照抄 TheBall 2.7**（用户 2026-10-18 定案：
//     「我手机上那个 TheBall 点、拖、双击全没问题」）。
//
// 反汇编 TheBall 的 `HUDMainWindow`，它一共覆盖 **9 个方法**，我们以前只有 3 个：
//   +_isSystemWindow                          = YES   （我们原来就有）
//   -_isWindowServerHostingManaged            = NO    （我们原来就有）
//   -_ignoresHitTest                          = NO    （我们原来就有）
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
// ⚠️ 安全阀仍然在这两层（缺一不可）：
//   ① 本类的 hitTest: 遍历子视图，**没有一个命中就返回 nil**（触摸漏给下面的 App）；
//   ② 根视图是 FBPassThroughView，球以外一律返回 NO。
// 这两层是「万一吞掉整屏触摸」的最后保险，别动。
@implementation HUDMainWindow

+ (BOOL)_isSystemWindow { return YES; }

- (BOOL)_isWindowServerHostingManaged { return NO; }

- (BOOL)_ignoresHitTest { return NO; }

- (BOOL)_isSecure { return YES; }

- (BOOL)_shouldCreateContextAsSecure { return YES; }

- (BOOL)_shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation { return YES; }

- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

- (BOOL)shouldAutorotate { return YES; }

/// 照抄 TheBall：只把命中测试交给子视图；子视图都不认，就返回 nil（漏给下面）。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    for (UIView *sub in self.subviews) {
        UIView *hit = [sub hitTest:point withEvent:event];
        if (hit) return hit;
    }
    return nil;
}

@end
