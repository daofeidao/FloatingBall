//
//  HUDApp.mm
//
//  同一个二进制、两种身份：
//    argv 无参      -> 普通 App（设置界面）
//    argv[1]=-hud   -> 以 root 常驻的「悬浮球进程」，靠 assistivetouchd 的权限画全局窗口
//    argv[1]=-exit  -> 把正在跑的球进程杀掉
//    argv[1]=-check -> 球进程还活着吗
//
//  机制来源：Lessica/TrollSpeed -> limneos/UIDaemon -> leminlimez/Helium -> 本项目
//

#import <notify.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <sys/stat.h>
#import <errno.h>
#import <dlfcn.h>

#import "HUDHelper.h"
#import "FBLog.h"
#import "FBSystemActions.h"
#import "HUDMainWindow.h"

#import "../helpers/ts/TSEventFetcher.h"
#import "../helpers/private_headers/AXEventRepresentation.h"
#import "../helpers/private_headers/BackboardServices.h"
#import "../helpers/private_headers/UIApplication+Private.h"

// ============================================================================
// 触摸走哪条路（2026-10-17 真机结论，别再往回改）
//
// ❌ 原来的假设：「窗口能被 SpringBoard 托管 → 触摸也会送进我们进程」。
//    真机结果：**窗口显示完全正常（浮在所有 App 之上、每个界面都在），
//    但触摸一个都收不到** —— 点球时球上的数字一个都不涨，就是证据。
//    也就是说「小窗口直接吃触摸」这条路在 iOS 15.6.1 上不成立，
//    HUDMainWindow 的 _ignoresHitTest 改成 NO 也没用。
//
// ✅ 现在这条路：自己监听**全局 HID 事件**（BKSHIDEventRegisterEventCallback），
//    判断「这一下是不是按在球上」，是就把它喂成一次真正的 UITouch 给球视图。
//    机制来源：Lessica/TrollSpeed → Helium（都在生产用）。
//
//    ⚠️ 只「观察」不「拦截」：系统那份事件照样发给下面的 App，
//       所以点在球上时，球下面的 App 也会同时收到这一下。
//       这是这条路本身的限制（HID 回调没有「吃掉事件」的能力），先接受。
//
//    ⚠️ 只有「按下」落在球上才接管；接管之后它的 move / up 全归我们，
//       手指划出球的范围也不能丢，否则拖动会断在半路。
//
// --- 0.1.11 修正（2026-10-17 真机自检读数直接指向这里）---
//
//    自检（0.1.8 那版）：回调=30225（路A=0 路B=30225 匹配服务=1）、无rep=0、无路径=0、
//    非本触点=29458、不在球=0、接管=0、喂球=0。
//    → 事件**全部收到了**，但**一条「按下」都没被认出来**：`[rep isTouchDown]` 一直是 0。
//      而老逻辑只有「按下」才接管，所以永远接管不了 —— 这就是「点球没反应」的正主。
//
//    改法（对着工作正常的 TheBall 反汇编对齐的）：**phase 由我们自己定**，
//    起手落在球上就算 Began；AX 那几个标志只当补充，底层 IOHID 字段（Touch=0）判抬起。
//    另外把「窗口问到了」不再当成「真触摸这条路通了」——只有球的手势真触发过（真点击>0）
//    才停喂合成触摸，免得两边都关掉、球彻底没反应。
// ============================================================================
#define USE_HID_EVENT_CALLBACK 1

/// 当前被我们接管的触点 id（0 = 没有）
static NSInteger gFBActivePointer = 0;

/// 球视图（由 BallRootViewController 在 viewDidLoad 里注册进来）。
/// 触摸回调要靠它算「这一下是不是按在球上」。
static __weak UIView *gFBBallView = nil;

void FBHUDSetBallView(UIView *ballView)
{
    gFBBallView = ballView;
    FBLog(@"触摸回调已绑定球视图 frame=%@ window=%@",
          ballView ? NSStringFromCGRect(ballView.frame) : @"(nil)",
          ballView.window ? @"有" : @"无");
}

// ---- 快捷菜单浮层（0.1.22）----
static CGRect gFBMenuArea = CGRectZero;
static BOOL   gFBConsumeWholeScreen = NO;
/// 0.1.29：菜单视图本身。菜单上的触摸直接喂给它（不靠 hitTest 走到某一行）。
static __weak UIView *gFBMenuView = nil;

void FBHUDSetMenuArea(CGRect rectInWindow)
{
    gFBMenuArea = rectInWindow;
    FBLog(@"菜单区域更新 = %@（%@）", NSStringFromCGRect(rectInWindow),
          CGRectIsEmpty(rectInWindow) ? @"菜单已关" : @"菜单已开");
}

void FBHUDSetMenuView(UIView *menuView)
{
    gFBMenuView = menuView;
    FBLog(@"菜单视图更新 = %@", menuView ? NSStringFromClass([menuView class]) : @"(nil)");
}

void FBHUDSetConsumeWholeScreen(BOOL consume)
{
    gFBConsumeWholeScreen = consume;
    FBLog(@"全屏消费 = %@（菜单开着时会接管整屏，用来接「点外面关菜单」）",
          consume ? @"是" : @"否");
}

// ============================================================================
// 触摸自检（2026-10-17 加：用户报「点球直接穿透、球没反应」）
//
// 这条链子是**一路静默**的，断在哪一段表现都一模一样（球不动）：
//   ① 回调被调了吗 → ② AXEventRepresentation 转出来了吗 → ③ 有没有手指路径 / 身份号
//   → ④ 这一下落在球的矩形里吗 → ⑤ 接管 + 喂给球视图了吗
//
// 所以这里把每段的计数和「最后停在哪」写一份到 /tmp/FloatingBall.probe，
// App 的「关于」页会把它读出来显示 —— 用户在手机上不开终端也能把这一行念给我。
// ⚠️ 只写这一个文件（限速 1 秒 1 次），**绝不碰设置那份 plist**，免得把用户的设置写坏。
//
// 0.1.6 真机结果：**回调=0，按音量键也不涨** —— 说明 BKSHIDEventRegisterEventCallback
// 这条路在 iOS 15.6.1 上一条事件都收不到（同门的 TrollSpeed / Helium / TheBall
// 都是同一份代码，而它们的 HUD 只用来「显示」，所以这条路从来没被验证过）。
// 0.1.7 起多了一条有据可查的路（IOHIDEventSystemClient 监视客户端，见下面
// `_HUDMonitorRouteCallback` 的注释），两条路分别计数，谁生效看 路A= / 路B=。
//
// 0.1.8 真机读数：路B 收到 30225 条，却**一条「按下」都没有**（接管=0）——
//   于是 0.1.11 把「谁来当按下」改成自己判（见文件顶部），并加了一行「底层」：
//     底层：AX按下=A 在屏=B 离屏=C
//   · AX按下 —— AXEventRepresentation 的 isTouchDown 说了几次「按下」（老逻辑唯一入口）
//   · 在屏 / 离屏 —— 直接读 IOHID 事件字段（Touch=1 / Touch=0），注入工具 ZXTouch 用的同一套
//   读法：在屏>0 说明「事件流里确实有手指」；这时候球还不响应，就看「最后」一行的
//   点 / 球 / 窗口 三个矩形（判断坐标系）和 hid(x=…) 那几位。
// ============================================================================
#define FB_PROBE_PATH   @"/tmp/FloatingBall.probe"

static int    sProbeCallbacks = 0;   // ① 回调进来了几次（两条路合计）
static int    sProbeRouteA    = 0;   // ① 其中来自「BKS 回调」那条路的
static int    sProbeRouteB    = 0;   // ① 其中来自「监视客户端」那条路的
static int    sProbeMatched   = -1;  // 监视客户端按 13/4 匹配到几个触摸屏服务（-1 = 没问）
static int    sProbeNoRep     = 0;   // ② rep 转不出来
static int    sProbeNoPath    = 0;   // ③ 没有手指路径（按键 / 父事件都走这里）
static int    sProbeZeroID    = 0;   // ③ pathIdentity<=0（当 1 用了）
static int    sProbeNotOurs   = 0;   // ④ 无关的「抬起」（没拿着的时候收到的）
static int    sProbeOffBall   = 0;   // ④ 起手不在球上（留给下面的 App）
static int    sProbeOtherRoute = 0;  // 另一条路又送来的触摸（只记数，不喂，防重复）
static int    sProbeTakeover  = 0;   // ⑤ 接管了（起手落在球上）
static int    sProbeFed       = 0;   // ⑤ 喂给球视图了
static int    sProbeThrottled = 0;   // 0.1.19：被节流掉的高频移动事件
static int    sProbeReused   = 0;   // 0.1.21：拖动时坐标不可信、沿用上一帧的次数

/// 0.1.22：这一轮触摸（从起手开始）里有没有收到过 Moved。
/// 手指按住不动时数字器**不会**产生新事件，所以「没收到过 Moved」= 用户在长按，
/// 不是「触点卡死」。用它把 timeout 挡掉（不然长按会每秒震一下）。
static BOOL   sSawMoveSinceBegin = NO;
// ---- 底层字段（0.1.11 加，0.1.14 改「翻子事件」）----
static int    sProbeAXDown    = 0;   // AX 的 isTouchDown 说过几次「按下」
// 0.1.14：深读（会翻子事件）的三个计数 —— 这是判断「字段到底读得到读不到」的关键
static int    sProbeDeepFinger = 0;  // 深读说「有手指」（touch 或 range = 1）
static int    sProbeDeepUp     = 0;  // 深读说「没手指」（touch=0 且 range=0）
static int    sProbeDeepNone   = 0;  // 深读什么都没读到（这条事件上没有手指信息）
static NSTimeInterval sLastFedAt = 0; // 最近一次喂球的时间（「抬起没送到」的兜底用）
static CGPoint sLastFedPoint = CGPointZero;  // 最近一次喂球的窗口坐标（兜底补「抬起」要用同一个点）
static BOOL   sHIDSawTouch    = NO;  // 本次运行里深读真见过「有手指」——upNow 的兜底仍会读它
static BOOL   sSawLiftSignal  = NO;  // 收到过任何一种「抬起」信号（决定超时兜底用 1.2s 还是 0.55s）
static NSString *sLastEndReason = @"（还没结束过）";   // 上一次触摸是怎么结束的（写进诊断）
static NSUInteger sFeedGeneration = 0;   // 喂球代次：定时兜底只看最新一代（0.1.16）
static NSTimeInterval sLastEventAt = 0;  // 上一条触摸事件的时间（判「新一轮第一下」）
static NSString *sProbeLast   = @"（还没收到过任何 HID 事件）";
static NSTimeInterval sProbeLastWrite = 0;

// ---- 真触摸那条路（0.1.8 新加：窗口重新参与命中测试之后）----
// 这三个数是判断「路通没通」的关键，读法：
//   窗口问=0            → 触摸根本没送进这个窗口（窗口那道闸还是没开对）
//   窗口问>0 落在球=0    → 触摸进来了，但没落在球上（球的位置 / 坐标系对不上）
//   落在球>0 真点击=0    → 触摸喂到球上了，手势却没认出来（手势本身的问题）
static int sProbeHitAsk  = 0;   // 根视图被问到「这个点是不是你的」的次数
static int sProbeHitBall = 0;   // 其中落在球（含 6pt 宽容区）上的
static int sProbeRealTap = 0;   // 球自己的单击手势真的触发了
static int sProbeSelfTest = 0;  // 「自喂一次点击」做了几次（0.1.14）

// ---- 0.1.19 / 0.1.20：熔断判据 ----
//
// ⚠️⚠️ 0.1.19 在这里栽了，而且是真机立刻逮到（用户：连点只有第一下有反应，
//    间隔 1~2 秒才恢复）。0.1.19 用 `sSysAskBallAt` 当「系统真的派发了触摸」的证据，
//    由 FBProbeTouchHit(onBall=YES) 记 —— 可是 **FBProbeTouchHit 是 pointInside 调的，
//    而 pointInside 不分是谁问的**：我们自己那条
//      `[window hitTest:winPt withEvent:nil]`（在 FBHandleHIDEvent 里）
//    同样会走到 pointInside → sSysAskBallAt 被填上 →
//    熔断的三个条件在**第一次点击成功后**全部满足 →
//    第二次点击（2 秒内）被判定成「系统真触摸已通」→ 第一行就 return → **连点全废**。
//
// 0.1.20 换判据：只认「**不是我们合成**的 onSingleTap」。
// 这件事没法靠 pointInside 判断，只能靠「有没有走过合成起手那条路」：
//   合成触摸在喂 Began 的那一刻会调 FBBallHapticTouchDown()，那里记下时刻；
//   onSingleTap 触发时（0.3 秒后）如果距离那个时刻不到 grace，就是合成触摸，**不算证据**。
static NSTimeInterval sSynthTapAt = 0;   // 我们自己合成触摸「起手」的时刻
/// 确认为**非合成**的手势最近一次触发的时刻（= 系统真触摸的证据）。
static NSTimeInterval sGestureAt = 0;
/// 真触摸路线一旦被判定为「通」，多久之后强制回退到合成路线（秒）。
static const NSTimeInterval kRealTouchGrace = 2.0;

/// 自喂测试进行中：球的手势认出来之后**只记账、不执行绑定动作**
/// （否则「测试一下」会顺手打开设置/跑一个手势动作，太吓人）
BOOL gFBSelfTestTapPending = NO;

/// 盲喂模式（0.1.15，只在「关于」页手动打开）：不看坐标，任何一下触摸都当点球。
/// 用途：验证「HID 事件流里到底有没有真手指」——如果盲喂时球能响应，
/// 说明事件有、只是坐标对不上；如果盲喂也没反应，说明事件流里根本没有手指。
BOOL gFBBlindFeed = NO;

/// 活跃触摸来源：0 = 还没定，1 = 路A（BKS 回调），2 = 路B（监视客户端）
static int gHIDActiveRoute = 0;

// 0.1.27→0.1.28：原「是否退回合成兜底」的状态已随早退逻辑整段删除；
// sForceSynthetic 仍保留给诊断（FBProbeWrite）显示，不再参与判定。
static BOOL sForceSynthetic = NO;  // 诊断用：是否曾退回合成兜底（0.1.28 起恒为 NO）

static void FBProbeWrite(BOOL force)
{
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!force && now - sProbeLastWrite < 1.0) return;
    sProbeLastWrite = now;
    BOOL pt = [HUDMainWindow fb_passThrough];
    NSString *text = [NSString stringWithFormat:
        @"回调=%d（路A=%d 路B=%d 匹配服务=%d） 无rep=%d 无路径=%d id<=0=%d "
        @"不在球=%d 非本触点=%d 另一条路=%d 接管=%d 喂球=%d 节流=%d 沿用上一帧=%d\n"
        @"真触摸：窗口问=%d 落在球=%d 真点击=%d 自喂测试=%d\n"
        @"底层：AX按下=%d 深读(有手指=%d 没手指=%d 读不到=%d)\n"
        @"路线：穿透=%d 合成兜底=%d\n最后：%@\n",
        sProbeCallbacks, sProbeRouteA, sProbeRouteB, sProbeMatched,
        sProbeNoRep, sProbeNoPath, sProbeZeroID,
        sProbeOffBall, sProbeNotOurs, sProbeOtherRoute, sProbeTakeover, sProbeFed,
        sProbeThrottled, sProbeReused,
        sProbeHitAsk, sProbeHitBall, sProbeRealTap, sProbeSelfTest,
        sProbeAXDown, sProbeDeepFinger, sProbeDeepUp, sProbeDeepNone,
        (int)pt, (int)sForceSynthetic, sProbeLast];
    [text writeToFile:FB_PROBE_PATH atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static void FBProbeNote(NSString *reason)
{
    sProbeLast = reason;
    FBProbeWrite(NO);
}

// ============================================================================
// 0.1.15：给 App 看的「真实点球诊断」
//
// 自喂测试已经证明**喂球那条路是通的**（球会震、计数会加），所以剩下的问题
// 只可能在「这一下算不算按在球上」。这个文件把每一步的**原始数字**写出来，
// App 的「关于」页直接翻译成一句人话 —— 用户不用读数、不用开终端。
// 只写 /tmp 下这一个文件，限速 0.4 秒 1 次（接管那一刻强制写）。
// ============================================================================
static NSTimeInterval sDiagLastWrite = 0;

static void FBWriteTouchDiag(BOOL fed, BOOL onBall, BOOL tookOver,
                             CGPoint rawPt, CGPoint winPt, CGRect ballWin,
                             BOOL hidOK, int touch, int range,
                             BOOL axDown, BOOL axMove, BOOL axLift,
                             BOOL axInRangeLift, BOOL axCancel)
{
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!tookOver && now - sDiagLastWrite < 0.4) return;
    sDiagLastWrite = now;

    NSString *deep = @"读不到";
    if (hidOK) deep = ((touch == 1 || range == 1) ? @"有手指" : @"没手指");

    CGRect sb = [UIScreen mainScreen].bounds;
    NSString *text = [NSString stringWithFormat:
        @"当=%.2f\n"
        @"在球上=%d\n"
        @"接管=%d\n"
        @"喂球=%d\n"
        @"点=%.1f,%.1f\n"
        @"窗口点=%.1f,%.1f\n"
        @"球窗口=%.1f,%.1f,%.1f,%.1f\n"
        @"屏幕=%.0f,%.0f\n"
        @"深读=%@\n"
        @"AX=按下%d 移动%d 抬起%d 范围抬%d 取消%d\n"
        @"盲喂=%d\n"
        @"结束=%@\n"
        @"累计接管=%d 累计喂球=%d\n",
        now, (int)onBall, (int)tookOver, (int)fed,
        rawPt.x, rawPt.y, winPt.x, winPt.y,
        ballWin.origin.x, ballWin.origin.y, ballWin.size.width, ballWin.size.height,
        sb.size.width, sb.size.height, deep,
        (int)axDown, (int)axMove, (int)axLift, (int)axInRangeLift, (int)axCancel,
        (int)gFBBlindFeed, sLastEndReason, sProbeTakeover, sProbeFed];
    [text writeToFile:@"/tmp/FloatingBall.touchdiag"
           atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

void FBProbeTouchHit(BOOL onBall)
{
    sProbeHitAsk++;
    if (onBall) {
        sProbeHitBall++;
        if (sProbeHitBall == 1) FBLog(@"真触摸：窗口问到了，而且落在球上（这条路通了）");
    }
    FBProbeWrite(NO);
}

void FBProbeRealTapDidFire(void)
{
    sProbeRealTap++;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    // ⚠️ 只有**不是**我们合成的那一下，才算「系统真触摸」的证据。
    //    合成触摸起手时 FBBallHapticTouchDown() 已经记下了 sSynthTapAt，
    //    而 onSingleTap 是在 0.3 秒之后才触发的（要等双击判定失败）——
    //    这段时间差远小于 grace，所以合成来的手势一定会被排除掉。
    if (now - sSynthTapAt > kRealTouchGrace) sGestureAt = now;
    if (sProbeRealTap == 1) FBLog(@"真触摸：球自己的单击手势触发了");
    FBProbeWrite(NO);
}

int FBProbeRealTapCount(void)
{
    return sProbeRealTap;
}

// ============================================================================
// 0.1.14：自喂一次点击（「关于」页那个测试按钮）
//
// 为什么要它：这条链断在哪一段，从外面完全看不出来 ——
//   (a) 检测层没认出「这一下在球上」→ 自定义触摸根本没发出来；
//   (b) 发出来了，但 UIKit 没把触摸交给球 → 手势不触发。
// 这个测试**绕过检测层**，直接用球心的窗口坐标喂一次「按下 + 抬起」：
//   · 球动了 / 自检里「真点击」+1  → 检测层是唯一的毛病（那就去看「最后」一行）
//   · 一点反应都没有               → 喂球这条路本身没通（下一版就改这条路）
// 测试期间只记账、**不执行**绑定动作（见 gFBSelfTestTapPending）。
// ============================================================================
void FBSelfTestFeedTap(void)
{
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        UIView *ball = gFBBallView;
        UIWindow *window = ball.window;
        if (!ball || !window) {
            FBProbeNote(@"[自喂测试] 球 / 窗口还没就绪（ball 或 window 是空的）");
            return;
        }

        CGPoint center = CGPointMake(CGRectGetMidX(ball.bounds), CGRectGetMidY(ball.bounds));
        CGPoint winPt = [ball convertPoint:center toView:window];
        UIView *hit = [window hitTest:winPt withEvent:nil];
        UIView *feedView = (hit && hit != window) ? hit : ball;

        sProbeSelfTest++;
        gFBSelfTestTapPending = YES;

        NSInteger pid = 99;   // TSEventFetcher 一共 100 个槽位，最后一个专门留给自测
        // ⚠️ 0.1.20：自喂测试原来**没有任何可见/可感反馈** —— 用户点了「自喂测试」
        //    只看到「点击次数 +1」，球不缩、也不震，于是完全分不清「测试到底跑没跑」
        //    （用户 2026-10-18 原话：「自喂测试 - 没感觉有变化」）。
        //    现在和真触摸走同一个入口：按下就缩一下 + 震一下。
        //    注意也要记 sSynthTapAt —— 它同样是**合成**的，
        //    不记的话这次自喂触发的 onSingleTap 会被当成「系统真触摸」的证据。
        sSynthTapAt = [NSDate timeIntervalSinceReferenceDate];
        FBBallHapticTouchDown();

        FBLog(@"[自喂测试] 往球心喂一次点击：窗口点=(%.1f,%.1f) hit=%@ -> onView=%@",
              winPt.x, winPt.y, hit ? NSStringFromClass([hit class]) : @"(nil)",
              NSStringFromClass([feedView class]));

        [TSEventFetcher receiveAXEventID:pid
                      atGlobalCoordinate:winPt
                          withTouchPhase:UITouchPhaseBegan
                                inWindow:window
                                  onView:feedView];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [TSEventFetcher receiveAXEventID:pid
                          atGlobalCoordinate:winPt
                              withTouchPhase:UITouchPhaseEnded
                                    inWindow:window
                                      onView:feedView];
            FBProbeNote([NSString stringWithFormat:
                @"[自喂测试] 已喂完（真点击累计=%d）—— 球上有没有反应？", sProbeRealTap]);
            // 兜底：万一手势没认出来，别让这个标记一直挂着
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (gFBSelfTestTapPending) {
                    gFBSelfTestTapPending = NO;
                    FBLog(@"[自喂测试] 1 秒内手势没被认出来（这次测试=失败）");
                }
            });
        });
    });
}

/// 真触摸这条路是不是已经通了？通了就别再喂合成触摸（否则一次点击走两遍）。
///
/// ⚠️⚠️ 这里改过两次，两次都是被真机打回来的，记下来别再走回头路：
///
/// **0.1.8~0.1.18（`return sProbeRealTap > 0;`）—— 自熔断**
///    `sProbeRealTap` 是在 `onSingleTap:` 里加的，而 `onSingleTap:` 同样会被**我们自己
///    合成的**触摸触发。于是第一次点球成功就把「系统真触摸已通」坐实 → 不再喂合成触摸
///    → 球彻底死掉（「只有第一下有用」）。「关于」页的自喂测试按钮也踩同一个雷。
///
/// **0.1.19（加 `sSysAskBallAt`）—— 还是自熔断，换了个姿势**
///    以为 `FBProbeTouchHit`（pointInside 调的）能证明「这一下是系统派发的」。
///    可 pointInside **根本分不清是谁问的** —— 我们自己那条
///    `[window hitTest:winPt withEvent:nil]` 也会走到它。于是第一次点击成功后
///    三个条件全部满足 → **连点只有第一下有反应，间隔 1~2 秒才恢复**（用户实测）。
///
/// **0.1.20（现在）—— 只认「非合成」的手势**
///    合成的触摸在喂 Began 时会调 `FBBallHapticTouchDown()`，那里记 `sSynthTapAt`；
///    `onSingleTap` 触发时距那个时刻只有 0.3 秒（等双击判定失败），远小于 grace，
///    一律排除。`sGestureAt` 只会被**真正来自系统**的手势填上。
///
/// 至于「系统到底会不会派发真触摸给我们」：0.1.8~0.1.17 的自检「窗口问=0」是硬证据，
/// 说 iOS 15.1+ 不会。所以这条熔断在真机上**永远不会触发** —— 它只是保险。
/// 真要彻底去掉熔断也不影响功能，只是将来万一换了系统版本就没有双击保护了。
BOOL FBRealTouchWorks(void)
{
    if (sGestureAt <= 0) return NO;               // 从来没有非合成的手势 → 系统真触摸不存在
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - sGestureAt > kRealTouchGrace) return NO;   // 太久没有真触摸了 → 回退合成
    return YES;
}

/// 两条路（BKS 回调 / 监视客户端）**共用**的处理函数。
/// route：1 = BKSHIDEventRegisterEventCallback 那条（0.1.3~0.1.6 用的）；
///        2 = IOHIDEventSystemClient 监视客户端那条（0.1.7 新加）。
static void FBHandleHIDEvent(int route, void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event)
{
    static UIApplication *app = [UIApplication sharedApplication];
    sProbeCallbacks++;
    if (route == 1) sProbeRouteA++; else sProbeRouteB++;
#if DEBUG
    os_log_debug(OS_LOG_DEFAULT, "_HUDEventCallback(route=%d) => %{public}@", route, event);
#endif

    // 顺手把真机的 sender ID 学下来：注入触摸（全局返回）必须用它。
    // 放在最前面 —— 下面有好几条早退分支，不管走哪条都先把这条记下来。
    // ⚠️ 这里不会做任何加载（预热在启动时做过了），见 FBSystemActions.mm。
    FBHIDNoteRealEvent(event);

    // 0.1.28：推翻 0.1.27 的「真触摸优先 / 合成兜底」整段逻辑（下面那段已删）。
    // 原因：后台巨魔 App 收不到系统派发的真触摸 —— 0.1.19 自检「窗口问=0」已坐实，
    // 0.1.27 把合成一刀切掉后整版拖不动，是二次证据。TheBall 同样是后台巨魔 App，
    // 它也不是靠系统派发，而是自己监听 HID + 合成 UITouch 喂给自己的窗口。
    // 所以 FloatingBall 唯一能用的就是合成路线：**永远喂合成触摸**，不再做「等真触摸」的早退。
    // （`fb_passThrough` 现在只服务于窗口的 `_ignoresHitTest`，不再用于节流合成。）
    // 后台巨魔 App 收不到系统派发的真触摸，合成路线是唯一能用的，永远喂合成。

    // iOS 15.1+ 用 AXRuntime 那条路处理 HID 事件
    if (@available(iOS 15.1, *)) {}
    else {
        [app _enqueueHIDEvent:event];
    }

    BOOL shouldUseAXEvent = YES;
    BOOL isExactly15 = NO;
    static NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    if (version.majorVersion == 15 && version.minorVersion == 0 && version.patchVersion == 0) {
        isExactly15 = YES;
    }
    if (@available(iOS 15.0, *)) {
        shouldUseAXEvent = !isExactly15;
    } else {
        shouldUseAXEvent = NO;
    }

    if (!shouldUseAXEvent) return;

    static Class AXEventRepresentationCls = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/AccessibilityUtilities.framework"] load];
        AXEventRepresentationCls = objc_getClass("AXEventRepresentation");
    });
    if (!AXEventRepresentationCls) return;

    AXEventRepresentation *rep = [AXEventRepresentationCls representationWithHIDEvent:event
                                                                    hidStreamIdentifier:@"UIApplicationEvents"];
    if (!rep) {
        sProbeNoRep++;
        FBProbeNote([NSString stringWithFormat:@"② AXEventRepresentation 转不出来（etype=%d）",
                     FBHIDEventTypeOf(event)]);
        return;
    }

    NSArray *paths = [[rep handInfo] paths];
    if (paths.count == 0) {
        // 非触摸事件（按键、手势门……）和「只有父事件、没有手指」的情况都走这里
        sProbeNoPath++;
        FBProbeNote([NSString stringWithFormat:@"③ 没有手指路径（etype=%d）", FBHIDEventTypeOf(event)]);
        return;
    }

    NSInteger pointerId = [[paths firstObject] pathIdentity];
    if (pointerId <= 0) {
        // ⚠️ 以前这里直接 return：万一这台机器上真手指的 pathIdentity 就是 0，
        //    所有触摸都会被丢掉 —— 表现正好是「点球直接穿透、球没反应」。
        //    现在改成「当 1 用」并记一笔，宁可多喂一次也不整条路哑掉。
        sProbeZeroID++;
        pointerId = 1;
    }
    pointerId = MIN(MAX(pointerId, 1), 98);   // TSEventFetcher 一共 100 个槽位

    // 两条路可能都活着 —— 同一根手指绝不能被喂两遍（那样手势会错乱）。
    // 规则：第一条「触摸」事件来自哪条路，哪条就是活跃路；另一条之后只计数。
    if (gHIDActiveRoute == 0) {
        gHIDActiveRoute = route;
        FBProbeNote([NSString stringWithFormat:@"第一条触摸事件来自%@（之后按这条走）",
                     route == 1 ? @"路A：BKS 回调" : @"路B：监视客户端"]);
    } else if (gHIDActiveRoute != route) {
        sProbeOtherRoute++;
        FBProbeWrite(NO);
        return;
    }

    // ---- 手指状态（0.1.14 重写）----
    // ⚠️⚠️ 0.1.11~0.1.13「怎么点都完全没反应」的根子就在这儿：
    //    监听到的 `event` 是**父事件（collection）**，Touch / Range / X / Y 这些字段
    //    都在**子事件**（每根手指一个，type 也是 11）身上。直接对父事件 GetIntegerValue
    //    读出来永远是 0 —— 于是「有手指」永不成立 → 一次都不接管 → 球彻底死。
    //    这跟 0.1.8 那组读数（3 万条事件、接管=0）是同一个病的两个版本。
    //    0.1.14 改用 FBHIDReadTouchDeep()：先读自己，读不到就翻 children。
    int hidTouch = -1, hidRange = -1;
    double hidNX = 0, hidNY = 0;
    BOOL hidOK = FBHIDReadTouchDeep(event, &hidTouch, &hidRange, &hidNX, &hidNY) != 0;
    int hidMask = FBHIDDigitizerMaskOf(event);     // 原始 EventMask（只往自检里写）

    BOOL axDown        = [rep isTouchDown];
    BOOL axMove        = [rep isMove];
    BOOL axLift        = [rep isLift];
    BOOL axInRangeLift = [rep isInRangeLift];
    BOOL axCancel      = [rep isCancel];
    CGPoint location   = [rep location];           // 屏幕坐标？（下面三种来源都试）

    if (axDown) sProbeAXDown++;
    if (hidOK && (hidTouch == 1 || hidRange == 1)) sProbeDeepFinger++;
    else if (hidOK && hidTouch == 0 && hidRange == 0) sProbeDeepUp++;
    else sProbeDeepNone++;

    // 头 3 条事件原样记一笔：能看出「到底有没有触摸事件进来、长什么样」
    if (sProbeCallbacks <= 3) {
        FBLog(@"HID#%d etype=%d paths=%lu id=%ld ax(down=%d move=%d lift=%d) "
              @"深读(ok=%d touch=%d range=%d n=(%.3f,%.3f) mask=0x%x) 点=(%.0f,%.0f)",
              sProbeCallbacks, FBHIDEventTypeOf(event), (unsigned long)paths.count, (long)pointerId,
              (int)axDown, (int)axMove, (int)axLift,
              (int)hidOK, hidTouch, hidRange, hidNX, hidNY, hidMask, location.x, location.y);
    }

    // 「新的一下」判定：距离上一条触摸事件超过 150ms，就当新一根手指落下。
    // （只在 AX / 底层都不给「按下」信号时才用到 —— 最后一道保险。）
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval sinceLast = (sLastEventAt > 0) ? (now - sLastEventAt) : 999.0;
    sLastEventAt = now;
    BOOL firstInBurst = (sinceLast > 0.15);

    // ---- 0.1.19：进主队列**之前**就节流（关键：进了队列再丢就晚了）----
    //
    // 自检里「回调=30225」不是小数目：手指一移动就是每秒上百条 HID 事件。
    // 原来每一条都 dispatch_async 到主线程、每一条都做一遍 8 个候选点 +
    // `[window hitTest:]`。主队列会迅速积压，「按下」迟到几百毫秒 ——
    // **用户看到的就是「点了没反应 / 很迟钝」**，而且越用越卡（积压不会自己清）。
    //
    // 规则：
    //   · **起手永远放行** —— 单击 / 双击 / 长按全靠 Began，节流了就等于点不动；
    //   · **抬起也永远放行** —— click 的另一半，节流了就变成「按下去没反应」；
    //   · 只节流「已经在手上、既不是起手也不是抬起」的移动事件，限频 ~60Hz；
    //   · 新一轮（firstInBurst）也放行。
    //
    // ⚠️ 必须在这里（dispatch_async 之前）判断：进了队列再丢，「按下」已经排在后面了。
    //    读 sLastFedAt / sHIDSawTouch（主线程写的静态量）有竞态，
    //    但它们只决定节流激进与否，判错顶多多喂/少喂一条事件，没有正确性风险。
    {
        BOOL fingerNow = (hidOK && (hidTouch == 1 || hidRange == 1));
        BOOL beginNow = axDown || fingerNow || gFBBlindFeed;
        BOOL upNow    = axLift || axCancel || axInRangeLift
                     || (sHIDSawTouch && hidOK && !fingerNow);
        NSTimeInterval sinceFeed = (sLastFedAt > 0) ? (now - sLastFedAt) : 999.0;
        if (gFBActivePointer != 0 && !firstInBurst && !beginNow && !upNow && sinceFeed < 0.016) {
            sProbeThrottled++;
            return;
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^(void) {
        UIView *ball = gFBBallView;
        UIWindow *window = ball.window;
        if (!ball || !window) {
            FBProbeNote(@"⑤ 球视图还没就绪（ball / window 是空的）");
            return;
        }

        // ---- 坐标：把所有能拿到的来源都试一遍（0.1.15）----
        //   ① AX 的 [rep location]
        //   ② 每条手指路径自己的 pathLocation（AXEventPathInfoRepresentation）
        //   ③ 底层子事件的归一化 X/Y（×屏幕 = 点）/ 原样 / 除以 scale
        // 每个候选点再分「屏幕坐标」「窗口坐标」两种解释各试一次。
        CGRect ballWin  = [ball convertRect:ball.bounds toView:window];
        CGRect touchWin = CGRectInset(ballWin, -10.0, -10.0);   // 手指有宽度，放宽到 10pt
        CGRect screenRect = [UIScreen mainScreen].bounds;

        CGPoint cands[8];
        int candCount = 0;
        cands[candCount++] = location;                           // ①

        SEL pathLocSel = NSSelectorFromString(@"pathLocation");  // ②
        for (NSUInteger i = 0; i < paths.count && candCount < 6; i++) {
            id p = paths[i];
            if (![p respondsToSelector:pathLocSel]) break;
            CGPoint pt = ((CGPoint (*)(id, SEL))[p methodForSelector:pathLocSel])(p, pathLocSel);
            if (pt.x != 0.0 || pt.y != 0.0) cands[candCount++] = pt;
        }

        if (hidOK && (hidNX != 0.0 || hidNY != 0.0)) {           // ③
            if (hidNX <= 1.5 && hidNY <= 1.5) {
                cands[candCount++] = CGPointMake(hidNX * screenRect.size.width,
                                                 hidNY * screenRect.size.height);
            } else {
                cands[candCount++] = CGPointMake(hidNX, hidNY);
                CGFloat sc = [[UIScreen mainScreen] scale];
                if (sc > 1.0 && candCount < 8) {
                    cands[candCount++] = CGPointMake(hidNX / sc, hidNY / sc);
                }
            }
        }

        CGPoint winPt = [window convertPoint:location fromWindow:nil];
        BOOL onBall = NO;
        int matched = -1;
        // ⚠️ 0.1.22：菜单开着时，除了球还要认菜单的矩形。
        //
        // 0.1.29：菜单矩形优先**现场问视图**（gFBMenuView）。
        //    原来用打开那一刻算好的 gFBMenuArea，但菜单有 0.86→1.0 的出现动画，
        //    `convertRect:` 会把缩放算进去 → 存下来的矩形比真实菜单小一圈，
        //    点靠近边缘的行会被判成「菜单外」。现场算不受动画影响。
        UIView *menuView = gFBMenuView;
        CGRect menuRect = menuView ? [menuView convertRect:menuView.bounds toView:nil] : gFBMenuArea;
        CGRect menuTouch = CGRectInset(menuRect, -10.0, -10.0);   // 同样放宽 10pt 给手指
        BOOL hasMenu = !CGRectIsNull(menuRect) && !CGRectIsEmpty(menuRect);

        // ---- 第一轮：球 / 菜单里的点（决定 onBall、onMenu）----
        for (int i = 0; i < candCount; i++) {
            if (cands[i].x == 0.0 && cands[i].y == 0.0) continue;   // 没手指的事件常带 (0,0)
            CGPoint asScreen = [window convertPoint:cands[i] fromWindow:nil];
            if (CGRectContainsPoint(touchWin, asScreen)) { winPt = asScreen; onBall = YES; matched = i; break; }
            if (CGRectContainsPoint(touchWin, cands[i])) { winPt = cands[i]; onBall = YES; matched = i; break; }
            // 候选点虽然不在球上，但可能落在菜单上 —— 那也要认（菜单点不动等于没做）
            if (hasMenu) {
                if (CGRectContainsPoint(menuTouch, asScreen)) { winPt = asScreen; matched = i; break; }
                if (CGRectContainsPoint(menuTouch, cands[i])) { winPt = cands[i]; matched = i; break; }
            }
        }

        // ---- 第二轮：不在球/菜单里，但**落在屏幕/窗口内**的候选点 ----
        //
        // ⚠️⚠️ 0.1.22 修「拖动不跟手」（用户实测：拖球时球只在原地缩放，不跟着手走）。
        //
        //    第一轮一个都没匹配上时，`winPt` 保持 `[rep location]` 换算来的值。
        //    而 `[rep location]` 读的是 HID **父事件**（collection）—— 0.1.14 已经查明
        //    父事件上没有坐标、坐标全在**子事件**上。所以移动事件的 location 经常是
        //    (0,0) 或某个固定值 → 一路 bogus → 沿用上一帧坐标 → 球钉在原地不动。
        //
        //    候选点 ③（`hidNX/hidNY`，来自会翻子事件的 `FBHIDReadTouchDeep`）
        //    才是拖动时真正能拿到真坐标的来源。所以这里补一轮：
        //    **只要有一个候选点落在屏幕范围内，就用它**（哪怕它在球外面）——
        //    手指本来就该能拖出球。
        //
        // ⚠️⚠️ 0.1.24：0.1.22 这一轮**在白写**（用户 2026-10-18 实测「仍然不能拖动」）。
        //
        //    原来的进入条件是 `matched < 0 && !CGRectContainsPoint(screenRect, winPt)`，
        //    想表达「winPt 不可信时才另找」。但这台设备的 location 恒为 **(0,0)**
        //    （0.1.16 修「快速拖动跳到左上角」时已经用事实确认过），换算后 winPt≈(0,0)，
        //    而 (0,0) 是屏幕左上角、**在矩形内** → `!CGRectContainsPoint(...)` 恒为 false
        //    → 第二轮一次都没跑过 → 坐标永远走「沿用上一帧」→ 球永远钉在原地。
        //    （(0,0) 既能当「空坐标」又能当「合法屏内点」，CGRectContainsPoint 分不清。）
        //
        //    现在：**第一轮没匹配上就跑第二轮**，不再看 winPt 在不在屏内 ——
        //    第一轮都没匹配上时，winPt 就只剩「未换算的 [rep location]」这一个来源，
        //    在这台设备上它本来就是废的。cands[0] 就是 location 本身：
        //    location 真有效时它排在第一个、屏内判定先命中它，winPt 不变（行为无差别）；
        //    location 是 (0,0) 时它被跳过，顺位让给子事件的真坐标。
        //    另外补一个「原样当窗口坐标」的解释：路径点可能是窗口系而非屏幕系，
        //    只按屏内判会把真坐标误杀（窗口理论上是全屏的，两条判定几乎等价，图个稳）。
        if (matched < 0) {
            for (int i = 0; i < candCount; i++) {
                if (cands[i].x == 0.0 && cands[i].y == 0.0) continue;
                CGPoint asScreen = [window convertPoint:cands[i] fromWindow:nil];
                if (CGRectContainsPoint(screenRect, asScreen)) { winPt = asScreen; matched = i; break; }
                if (CGRectContainsPoint(window.bounds, cands[i])) { winPt = cands[i]; matched = i; break; }
            }
        }

        BOOL onMenu = hasMenu && CGRectContainsPoint(menuTouch, winPt);

        // 「盲喂」= 不看坐标，任何一下都当点球（只在用户手动打开的测试模式下）
        // ⚠️ 0.1.22：菜单开着时**整屏都接管** —— 那一下如果不在菜单上，
        //    作用就是把菜单关掉。要是只接管菜单矩形，用户点外面我们根本收不到，
        //    菜单就永远关不掉。
        BOOL takeOverArea = onBall || onMenu || gFBBlindFeed || gFBConsumeWholeScreen;

        // ---- 0.1.17：手指不会瞬移 ----
        // 触点还活着时，新事件的点离上一次喂过的点太远（>90pt 且隔了 30ms 以上），
        // 那一定是**新的一下**，不是这一根的移动 —— 先把旧的结束，再按新触点处理。
        // （修「只有第一下有用」：后面的点击全被并成第一根的「移动」，于是再也没有新触摸）
        //
        // ⚠️⚠️ 0.1.22 修「拖不动 + 每秒震一下」（用户 2026-10-18 实测：
        //    「拖球不跟手，只在原地缩放一下」；「长按每隔 1 秒震一下」）。
        //
        //    原来这个「跳点」判定直接拿 **未经修正的 `winPt`** 去和 `sLastFedPoint` 比。
        //    而拖动/长按时，移动事件里 `[rep location]` 经常读不到有效坐标
        //    （退化成 (0,0) 或某个固定值）—— 于��它每次都「跳了三四百 pt」→ 每次都补抬起
        //    → 下一条又变成新起手 → 每秒一次「补抬起 + 重新起手」= 每秒震一下、球原地缩放。
        //
        //    **关键**：`bogusPoint`（下面算）本来就是干「这一帧坐标不可信」这件事的，
        //    但它算在**这段之后**，所以修正根本来不及生效 —— 两个机制在做同一件事，
        //    而且抢先的那个用的是坏数据。
        //    现在：**坐标不可信时不算「跳点」**（沿用上一帧坐标继续移动），
        //    只有坐标可信（真的在屏内、不是 (0,0)）且位移异常时才算跳点。
        if (gFBActivePointer != 0 && sLastFedAt > 0) {
            BOOL ptUnreliable = (location.x == 0.0 && location.y == 0.0)
                             || winPt.x < -30.0 || winPt.y < -30.0
                             || winPt.x > screenRect.size.width + 30.0
                             || winPt.y > screenRect.size.height + 30.0;
            if (!ptUnreliable) {
                CGFloat dx = winPt.x - sLastFedPoint.x;
                CGFloat dy = winPt.y - sLastFedPoint.y;
                if (dx * dx + dy * dy > 90.0 * 90.0 && (now - sLastFedAt) > 0.03) {
                    [TSEventFetcher receiveAXEventID:gFBActivePointer
                                  atGlobalCoordinate:sLastFedPoint
                                      withTouchPhase:UITouchPhaseEnded
                                            inWindow:window
                                              onView:ball];
                    FBLog(@"触摸：点跳了 %.0fpt（%.0f,%.0f → %.0f,%.0f），先把触点 %ld 结束掉",
                          sqrt(dx * dx + dy * dy),
                          sLastFedPoint.x, sLastFedPoint.y, winPt.x, winPt.y,
                          (long)gFBActivePointer);
                    sLastEndReason = @"跳点补抬起";
                    gFBActivePointer = 0;
                }
            }
        }

        // ---- 0.1.16：先处理「上一轮还没结束，但事件流已经断档」----
        // 真机上「点一下之后球就卡死」的成因：抬起事件没送到 → 我们一直攥着假触点 →
        // 后面的点击全被当成这一根的「移动」→ 不会再产生新的触摸 → 手势再也不触发。
        // 断档 >120ms 就说明上一轮早结束了：先补一个「抬起」交还，再按新的一下处理。
        if (gFBActivePointer != 0 && firstInBurst) {
            [TSEventFetcher receiveAXEventID:gFBActivePointer
                          atGlobalCoordinate:sLastFedPoint
                              withTouchPhase:UITouchPhaseEnded
                                    inWindow:window
                                      onView:ball];
            FBLog(@"触摸：断档 %.0fms，先把上一轮触点 %ld 结束掉（%.0f,%.0f）",
                  sinceLast * 1000.0, (long)gFBActivePointer,
                  sLastFedPoint.x, sLastFedPoint.y);
            sLastEndReason = @"断档补抬起";
            gFBActivePointer = 0;
        }

        // 让 UIKit 自己回答「这一点属于谁」—— 和 TheBall 一样的做法。
        // 顺带喂出「窗口问」那个自检（pointInside 里记的），比手算矩形更可信。
        UIView *hit = nil;
        if (takeOverArea) hit = [window hitTest:winPt withEvent:nil];
        UIView *feedView = (hit && hit != window) ? hit : ball;

        // ⚠️ 0.1.29：菜单上的触摸**直接喂给菜单容器**。
        //    别依赖 hitTest 走到哪一行 —— 合成触摸的抬起坐标可能丢（本机常见），
        //    而 UIControl 的 touchUpInside 严格要求「抬起时还在这一行」，一丢就不触发。
        //    改成：容器自己实现 touchesBegan/Ended，按坐标算行号，抬起坐标坏了也能用
        //    「按下时那一行」兜底。见 BallRootViewController 的 FBQuietMenuView。
        if (onMenu && menuView) {
            feedView = menuView;
        }

        // ---- 「抬起」判据（0.1.28 重做）----
        //   · 只认 AX 明说的三个信号：lift / cancel / inRangeLift。
        //   · **删掉** 0.1.15 加的两个兜底：`(sSawInRange && !axInRange)` 和 `(sHIDSawTouch && hidUp)`。
        //     它们是本机「松手后再点接不到」的真凶：`sSawInRange` / `sHIDSawTouch` 一旦见过就
        //     **永久锁存、从不复位**；而本机底层深读 (hidTouch/hidRange) 经常读不到、恒为 0，
        //     `axInRange` 在移动中也会抖一下变 NO。于是第一下能拖（锁存还没触发），松手后锁存，
        //     第二下刚按下、下一帧深读又读到 0 → 立刻判抬起 → 球永远接不到。
        //   · 漏掉的抬起靠下面的 0.18s 定时器 + 断档 + 超时兜底（0.1.17 已经这么干，
        //     第一下靠它也能正常结束），本机按住不动时事件流仍持续，不会误杀长按。
        //   · 深读字段 (hidTouch/hidRange) 仍用于「起手」判定（beganSignal），那条路不受影响。
        BOOL lifted = axLift || axCancel || axInRangeLift;
        if (lifted) sSawLiftSignal = YES;

        // 没有任何手指数据的「空事件」：坐标是 (0,0)，或者换算后跑到屏幕外面去了。
        // ⚠️ 这种事件如果当成「移动」喂进去，球会瞬间跳到左上角（用户报的那个 bug）。
        BOOL bogusPoint = !onBall && (
              (location.x == 0.0 && location.y == 0.0)
            || winPt.x < -30.0 || winPt.y < -30.0
            || winPt.x > screenRect.size.width + 30.0
            || winPt.y > screenRect.size.height + 30.0);

        UITouchPhase phase;
        BOOL isNewTouch = NO;
        BOOL tookOver = NO;
        // ⚠️ 0.1.21：这一帧要用「上一帧那个已知-good的坐标」而不是 winPt。
        //    见下面 bogusPoint 的处理。
        BOOL reuseLastPoint = NO;
        // 0.1.24：「触点还能攥多久」的超时值。提到 if 外面声明 ——
        // 下面 feedPt 的「陈旧坐标」判定要用同一个值（两处必须一致，
        // 否则会出现「超时没判钝、坐标先被判陈旧」的错位）。
        NSTimeInterval limit = sSawLiftSignal ? 1.6 : 1.0;

        if (gFBActivePointer != 0) {
            // 还攥着上一次的触点：抬起 / 超时 → 交还；否则继续当「移动」
            //
            // ⚠️⚠️ 0.1.21 修「拖不动 + 拖动时球反复缩放并连着震」（用户 2026-10-18 实测）
            //
            // 以前 `bogusPoint` 和 `timeout` **一样会直接把触点交还**：
            //   · 拖动时手指移出球 → `onBall` 变 false；坐标换算一旦落到屏幕外
            //     → 每一帧都判 bogus → 每一帧都 Ended → 下一帧又变成新起手。
            //   · 于是 **pan 永远积累不到足够的 `Changed` 事件 → 球拖不动**，
            //     而每一轮新起手都会调 `FBBallHapticTouchDown()` →
            //     **球反复缩放 + 反复震动**（盲喂测试时在球外拖动看得最清楚）。
            //
            // 现在：
            //   · `bogusPoint` 只用来**否决起手**（那才是它当初要防的「跳到左上角」），
            //     已经攥着触点时它只代表「这一帧的坐标不可信」→ 沿用上一帧坐标继续 Moved；
            //   · `timeout` 从 0.55 秒放宽到 1.0 秒（下面 limit 那一行）。
            //     单击/双击不受影响 —— 它们靠 tap 手势自己判完成，不靠这个超时。

            // ⚠️⚠️ 0.1.22 修「长按每隔 1 秒震一下」（用户实测）。
            //
            //    **手指按住不动时，数字器本来就不产生新的移动事件** —— 这是硬件行为。
            //    所以「长时间没有新事件」在长按场景下是**正常**的，
            //    而我们的 timeout 却把它当成「触点卡死、抬起送不到了」→ 补一个 Ended
            //    → 紧接着的新事件又变成**新起手** → FBBallHapticTouchDown()
            //    → **每秒震一下、球每秒缩一下**。用户描述得完全吻合。
            //
            //    判据：**这一轮里一条 Moved 都没收到过** = 手指一直没动 = 长按/按住，
            //    不是卡死 → 不走 timeout。（长按 0.5 秒要触发，靠的是 UIKit 那边
            //    UITouch 停在 Stationary 计时，本来就不需要我们持续喂 Moved。）
            //
            // ⚠️ 0.1.24：拖动进行中（收到过 Moved）停住瞄准，是**同一种硬件行为** ——
            //    手指停在屏幕上不动，数字器同样不发事件。1.0 秒的 limit 会把
            //    「拖到一半停住、瞄准、再继续」当成触点卡死 → 提前 End → 球吸边、
            //    剩下的拖动全部丢掉（表现为「拖一半球自己弹到边上」）。
            //    现在：没收过 Moved = 长按，完全不走超时；收到过 = 放宽到 2.5 秒。
            //    真卡死（抬起信号丢了）的恢复从 1.0 秒变成最多 2.5 秒 ——
            //    换慢拖动不被腰斩，值。（跳点/断档两道闸照旧，重按立刻重新起手。）
            if (!sSawMoveSinceBegin) {
                limit = DBL_MAX;                      // 长按：不走超时
            } else {
                limit = MAX(limit, 2.5);              // 拖动中暂停：放宽
            }
            BOOL timeout = (sLastFedAt > 0 && now - sLastFedAt > limit);

            // 盲喂模式专用的「别把球拖飞」保险：
            // 盲喂不看位置，所以**在屏幕上任何一处**起手都会被接管。修好连续性之后
            // 就会出现新问题 —— 用户在远处随手一划，球跟着那根手指满屏跑。
            // 这里给一道距离闸：离球太远就交还触点（正常模式根本不进这个分支，
            // 因为正常模式压根不会在球外起手）。
            BOOL tooFarFromBall = NO;
            if (gFBBlindFeed && !onBall) {
                CGFloat dxw = winPt.x - CGRectGetMidX(ballWin);
                CGFloat dyw = winPt.y - CGRectGetMidY(ballWin);
                tooFarFromBall = (dxw * dxw + dyw * dyw) > (150.0 * 150.0);
            }

            if (lifted) {
                phase = axCancel ? UITouchPhaseCancelled : UITouchPhaseEnded;
                sLastEndReason = axCancel ? @"取消信号" : @"抬起信号";
            } else if (timeout) {
                phase = axCancel ? UITouchPhaseCancelled : UITouchPhaseEnded;
                sLastEndReason = @"超时";
            } else if (tooFarFromBall) {
                phase = UITouchPhaseEnded;
                sLastEndReason = @"盲喂：离球太远，放手";
            } else if (bogusPoint) {
                phase = UITouchPhaseMoved;
                reuseLastPoint = YES;      // 坐标这一帧不可信，沿用上一帧
                sLastEndReason = @"空坐标(沿用上一帧)";
            } else {
                phase = UITouchPhaseMoved;
            }
            if (phase == UITouchPhaseMoved) sSawMoveSinceBegin = YES;   // 0.1.22
        } else {
            // 没有在手上的触点：这一下必须「落在球上」（盲喂模式下不看位置）
            BOOL beganSignal = axDown || (hidOK && (hidTouch == 1 || hidRange == 1)) || gFBBlindFeed;
            if (!takeOverArea || !(beganSignal || firstInBurst)) {
                sProbeOffBall++;
                FBProbeNote([NSString stringWithFormat:
                    @"④ 没接管（id=%ld 点=(%.0f,%.0f) 窗口点=(%.0f,%.0f) 球(窗口)=%@ "
                    @"在球上=%d 候选=%d 命中=%d 深读(ok=%d t=%d r=%d) ax(d=%d m=%d l=%d)）",
                    (long)pointerId, location.x, location.y, winPt.x, winPt.y,
                    NSStringFromCGRect(ballWin), (int)onBall, candCount, matched,
                    (int)hidOK, hidTouch, hidRange, (int)axDown, (int)axMove, (int)axLift]);
                FBWriteTouchDiag(NO, onBall, NO, location, winPt, ballWin,
                                 hidOK, hidTouch, hidRange, axDown, axMove, axLift,
                                 axInRangeLift, axCancel);
                return;
            }
            phase = UITouchPhaseBegan;
            isNewTouch = YES;
            tookOver = YES;
            sProbeTakeover++;
            sSawMoveSinceBegin = NO;   // 0.1.22：新的一轮，重置「有没有动过」
            FBProbeNote([NSString stringWithFormat:
                @"⑤ 起手在球上→接管（id=%ld 点=(%.0f,%.0f) 窗口点=(%.0f,%.0f) 球(窗口)=%@ "
                @"信号=%@ 候选=%d 命中=%d 深读(t=%d r=%d)）",
                (long)pointerId, location.x, location.y, winPt.x, winPt.y,
                NSStringFromCGRect(ballWin),
                gFBBlindFeed ? @"盲喂" : (axDown ? @"AX按下" : (firstInBurst ? @"新一轮第一下" : @"底层")),
                candCount, matched, hidTouch, hidRange]);
        }

        // ⚠️ atGlobalCoordinate 这个参数名是骗人的：TSEventFetcher 内部直接
        //    `setLocationInWindow:`，所以必须传**窗口坐标**，不能传屏幕坐标。
        //
        // ⚠️ 超时补的那个「抬起」要用**上一次喂过的点**：UITapGestureRecognizer 会因为
        //    「抬起位置离按下位置太远」判失败，而超时时手上这条事件的坐标很可能在别处。
        CGPoint feedPt = winPt;
        BOOL ending = (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled);
        if (gFBActivePointer != 0 && sLastFedPoint.x != 0 && sLastFedPoint.y != 0
            && (ending                                          // 0.1.29：抬起永远用最后一次好坐标
                || reuseLastPoint                               // 0.1.21：这一帧坐标不可信
                || (sLastFedAt > 0 && now - sLastFedAt > limit))) {   // 与超时用同一个 limit（0.1.24）
            feedPt = sLastFedPoint;
        }

        [TSEventFetcher receiveAXEventID:pointerId
                      atGlobalCoordinate:feedPt
                          withTouchPhase:phase
                                inWindow:window
                                  onView:feedView];

        // ⭐ 按下去就震（0.1.12）：最早、最不依赖手势的那一刻给一下「迎客」
        if (isNewTouch) {
            // 0.1.20：记下「这一下是我们合成的」。只有走得到这里的触摸才是合成的 ——
            // 系统真触摸根本进不来这个函数。FBProbeRealTapDidFire 靠它把
            // 「合成来的 onSingleTap」从「系统真触摸的证据」里排除掉
            // （0.1.19 正是因为没排除，连点只有第一下有反应）。
            sSynthTapAt = now;
            FBBallHapticTouchDown();
            // 盲喂模式下每一次都可能是误触：只让它记账/震一下，不执行绑定动作
            if (gFBBlindFeed) {
                gFBSelfTestTapPending = YES;
            }
        }

        sProbeFed++;
        sLastFedAt = now;
        // ⚠️ 0.1.25：存**真正喂出去的那个点**（feedPt），不是未经修正的 winPt。
        //    0.1.17 起的「坐标不可信就沿用上一帧」靠 sLastFedPoint 续命，
        //    但这里原来存的是坏点：一旦某一帧坐标读不到（拖动中手指移出球、
        //    或这台设备上 [rep location] 恒为 (0,0)），坏点就被永久记住 ——
        //    表现正是「球钉在原地不动 / 原地缩放」（用户 0.1.24 实测）。
        //    超时补抬起那段也用这个量，一起跟着修好了（不会再把球交到 (0,0)）。
        sLastFedPoint = feedPt;

        // 0.1.17：**定时兜底**（0.42 → 0.18 秒）。真机上抬起事件送不到，光靠「等下一条事件」
        // 永远等不到结束：一直攥着假触点，后面的点击全被吃掉 —— 就是「只有第一下有用」。
        // 0.18 秒没有新事件就自己交还：单击立即生效、双击不会被第一下吞掉。
        // 手指动的时候事件流不断（每来一条就换一代），所以拖动不会被误杀；
        // 只有「按住不动」时才会 0.18 秒交还 —— 长按要 0.5 秒，真机上能不能活看事件流是否持续。
        NSUInteger gen = ++sFeedGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gen != sFeedGeneration) return;       // 期间又来事件了 → 交给最新那一代
            if (gFBActivePointer == 0) return;
            [TSEventFetcher receiveAXEventID:gFBActivePointer
                          atGlobalCoordinate:sLastFedPoint
                              withTouchPhase:UITouchPhaseEnded
                                    inWindow:window
                                      onView:ball];
            FBLog(@"触摸：0.18 秒没新事件，自己交还触点 %ld（抬起事件没送到）",
                  (long)gFBActivePointer);
            sLastEndReason = @"定时器";
            gFBActivePointer = 0;
            FBProbeWrite(NO);
        });

        FBWriteTouchDiag(YES, onBall, tookOver, location, winPt, ballWin,
                         hidOK, hidTouch, hidRange, axDown, axMove, axLift,
                         axInRangeLift, axCancel);

        if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
            if (sProbeFed == 1 || isNewTouch) {
                FBLog(@"触摸：触点 %ld 交还（phase=%ld 原因=%@）",
                      (long)pointerId, (long)phase, sLastEndReason);
            }
            gFBActivePointer = 0;
        } else {
            if (isNewTouch) {
                FBLog(@"触摸：接管触点 %ld（窗口点 %.0f,%.0f）", (long)pointerId, winPt.x, winPt.y);
            } else if (reuseLastPoint) {
                // 0.1.21：拖动时最常见的这一支。原来它会把触点交还（→ 拖不动）。
                sProbeReused++;
                FBLog(@"触摸：这一帧坐标不可信，沿用上一帧 (%.0f,%.0f)（不交还触点）",
                      feedPt.x, feedPt.y);
            }
            gFBActivePointer = pointerId;
        }
        FBProbeWrite(NO);
    });
}

// ============================================================================
// 观察触摸的两条路（0.1.7）
//
// 路 A：`BKSHIDEventRegisterEventCallback` —— 0.1.3~0.1.6 用的就是它。
//   真机实测（0.1.6 自检）：**回调=0，按音量键也不涨**，一条事件都收不到。
//   同门的 TrollSpeed / Helium / TheBall 都是同一份代码，而它们的 HUD 只负责「显示」，
//   所以这条路其实从来没被验证过 —— 我们照抄了一个没跑通的用法。
//
// 路 B：`IOHIDEventSystemClient`「监视」客户端 —— 0.1.7 新加，有据可查：
//   · macPad 的 misc/ios_hid_touch_probe.m（按 iOS 16.3.1 反汇编写的观察/注入程序）
//   · ZXTouch 的 pccontrol/Touch.xm（真机在用的触摸自动化）
//   做法：CreateWithType(alloc, 1 = 监视, NULL) → SetMatching(触摸屏 13/4)
//        → RegisterEventCallback → ScheduleWithRunLoop(主 runloop)
//   「监视」类型是只看不吃：它不会拦掉系统事件（这点很重要，见文件开头那段说明）。
//
// 两条路的回调签名一模一样（target, refcon, service, event），共用 FBHandleHIDEvent；
// 谁先送来第一条触摸事件谁就是活跃路，另一条之后只计数不喂（防同一根手指喂两遍）。
// ============================================================================

static __used
void _HUDEventCallback(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event)
{
    FBHandleHIDEvent(1, target, refcon, service, event);
}

static __used
void _HUDMonitorRouteCallback(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event)
{
    FBHandleHIDEvent(2, target, refcon, service, event);
}

typedef CFTypeRef (*FBHIDCreateWithTypeFn)(CFAllocatorRef, uint32_t, CFDictionaryRef);
typedef CFTypeRef (*FBHIDCreateFn)(CFAllocatorRef);
typedef void (*FBHIDSetMatchingFn)(CFTypeRef, CFDictionaryRef);
typedef void (*FBHIDRegisterCallbackFn)(CFTypeRef, void (*)(void *, void *, CFTypeRef, CFTypeRef), void *, void *);
typedef void (*FBHIDScheduleFn)(CFTypeRef, CFRunLoopRef, CFStringRef);
typedef CFArrayRef (*FBHIDCopyServicesFn)(CFTypeRef);

static CFTypeRef (*fbCreateClientWithType)(CFAllocatorRef, uint32_t, CFDictionaryRef) = NULL;
static CFTypeRef (*fbCreateClient)(CFAllocatorRef) = NULL;
static void (*fbSetMatching)(CFTypeRef, CFDictionaryRef) = NULL;
static void (*fbRegisterEventCallback)(CFTypeRef, void (*)(void *, void *, CFTypeRef, CFTypeRef), void *, void *) = NULL;
static void (*fbScheduleWithRunLoop)(CFTypeRef, CFRunLoopRef, CFStringRef) = NULL;
static CFArrayRef (*fbCopyServices)(CFTypeRef) = NULL;

/// 取符号：先看进程里有没有，再退回单独 dlopen 的 IOKit。
/// ⚠️ 只在启动时调（回调里绝不做加载）。
static void *FBHIDSym(const char *name)
{
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) return p;
    static void *handle = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL);
    });
    return handle ? dlsym(handle, name) : NULL;
}

static void FBLoadObserverSymbols(void)
{
    if (fbRegisterEventCallback) return;
    fbCreateClientWithType  = (FBHIDCreateWithTypeFn)FBHIDSym("IOHIDEventSystemClientCreateWithType");
    fbCreateClient          = (FBHIDCreateFn)FBHIDSym("IOHIDEventSystemClientCreate");
    fbSetMatching           = (FBHIDSetMatchingFn)FBHIDSym("IOHIDEventSystemClientSetMatching");
    fbRegisterEventCallback = (FBHIDRegisterCallbackFn)FBHIDSym("IOHIDEventSystemClientRegisterEventCallback");
    fbScheduleWithRunLoop   = (FBHIDScheduleFn)FBHIDSym("IOHIDEventSystemClientScheduleWithRunLoop");
    fbCopyServices          = (FBHIDCopyServicesFn)FBHIDSym("IOHIDEventSystemClientCopyServices");
}

/// 触摸屏的匹配字典：PrimaryUsagePage 13（digitizer）+ PrimaryUsage 4（touchscreen）。
/// 只写这两个键，不写 Transport/Built-In —— 那两个键在别的机型上不一定成立，
/// 少写一点匹配面更大（匹配到几个服务会打进日志和自检里）。
static NSDictionary *FBTouchMatching(void)
{
    return @{ @"PrimaryUsagePage": @13, @"PrimaryUsage": @4 };
}

/// 路 B：建监视客户端并按触摸屏匹配，挂到主 runloop 上。
/// 返回客户端（调用方负责留着不释放，故意活到进程结束）。
static CFTypeRef FBStartHIDMonitor(void)
{
    FBLoadObserverSymbols();
    if (!fbRegisterEventCallback || !fbScheduleWithRunLoop ||
        (!fbCreateClientWithType && !fbCreateClient)) {
        FBLog(@"⚠️ 路B（监视客户端）不可用：IOHIDEventSystemClient 那几个符号取不全");
        return NULL;
    }

    CFTypeRef client = fbCreateClientWithType ? fbCreateClientWithType(kCFAllocatorDefault, 1, NULL)
                                              : fbCreateClient(kCFAllocatorDefault);
    if (!client) {
        FBLog(@"⚠️ 路B：建监视客户端失败（Create 回了 NULL）");
        return NULL;
    }

    if (fbSetMatching) fbSetMatching(client, (__bridge CFDictionaryRef)FBTouchMatching());
    fbRegisterEventCallback(client, (void (*)(void *, void *, CFTypeRef, CFTypeRef))_HUDMonitorRouteCallback, NULL, NULL);
    fbScheduleWithRunLoop(client, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    NSInteger matched = -1;
    if (fbCopyServices) {
        CFArrayRef services = fbCopyServices(client);
        if (services) {
            matched = (NSInteger)CFArrayGetCount(services);
            CFRelease(services);
        }
    }
    sProbeMatched = (int)matched;

    FBLog(@"路B（监视客户端）已建：%@ 匹配到 %ld 个触摸屏服务，已挂主 runloop",
          fbCreateClientWithType ? @"CreateWithType(type=1 监视)" : @"Create（没有 WithType，退回）",
          (long)matched);
    return client;
}

/// 万一 `BKSHIDEventRegisterEventCallback` 返回的真是个「事件系统客户端」，
/// 那它八成也要「匹配 + 挂 runloop」才会送事件 —— 就顺手替它做掉。
/// ⚠️ 只在类型确实对得上时才动它：对不上就什么都不做（免得拿野指针去喂 IOKit）。
static void FBMaybeScheduleBKSRoute(void *client)
{
    if (!client || !fbScheduleWithRunLoop || !fbCreateClient) return;

    uintptr_t value = (uintptr_t)client;
    if (value < 0x100000000ULL) {          // iOS 上正常指针绝不会这么小
        FBLog(@"路A：BKS 回调返回 %p，看着不像对象，先不碰它", client);
        return;
    }

    CFTypeRef probe = fbCreateClient(kCFAllocatorDefault);
    if (!probe) return;
    CFTypeID want = CFGetTypeID(probe);
    CFRelease(probe);

    if (CFGetTypeID((CFTypeRef)client) != want) {
        FBLog(@"路A：BKS 回调返回 %p，不是事件系统客户端（类型对不上），先不碰它", client);
        return;
    }

    if (fbSetMatching) fbSetMatching((CFTypeRef)client, (__bridge CFDictionaryRef)FBTouchMatching());
    fbScheduleWithRunLoop((CFTypeRef)client, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    FBLog(@"路A：BKS 回调返回的**确实是个事件系统客户端**，已替它匹配 + 挂 runloop（说不定就通了）");
}

#pragma mark -

/// ⚠️ pid 文件路径统一走 FBHUDPIDFilePath()（/tmp/FloatingBall.hud.pid）。
/// 0.1.11 之前这里用的是 NSCachesDirectory —— 球（uid 0）和 App（uid 501）两边
/// 解出来的目录不一样，App 根本读不到，只能靠再 spawn 一个 -check 进程去读，
/// 这就是「开关要等一两秒」的根因。现在两个进程读写同一份文件，App 直接读。

/// 退出时把 pid 文件删掉（atexit / -exit 都调它）。
static void FBHUDUnlinkPIDFile(void)
{
    unlink(FBHUDPIDFilePath().UTF8String);
}

#pragma mark -
#pragma mark ⚠️ 看门狗：App 被删，球跟着自尽（0.1.12 防「僵尸球」）
//
// 用户报的 bug：把悬浮球 App 删了，桌面上的球还留着，重启才能清掉。
// 原理上这不是「骨架选错」：球是 root 的独立进程，删 App = 把 .app 目录拆掉，
// **正在跑的进程不会被顺带杀死**（把文件删了进程照跑，这是 POSIX 的正常行为）。
// 原来缺的是一条规矩：「App 没了，球就该死」—— 现在补上。
//
// 判据：每隔几秒 stat 一下自己所在的 .app 目录（NSBundle mainBundle 的目录）。
//   · App 只是没开（正常长期状态）→ 目录还在 → 什么都不做；
//   · App 被删 → 目录没了 → 连续摸不到就退出。
//   连续 3 次（首查延迟 5 秒、之后每 3 秒一次，约 5~11 秒后生效）是因为
//   TrollStore 覆盖安装时会短暂拆掉重建目录，一次摸不到别急着判死刑，
//   免得用户更新 App 的时候球自己散场。
// 退出方式：exit(0) —— atexit 会把 pid 文件带走，进程一死，
// 托管给 SpringBoard 的窗口跟着回收，球就消失了（和「关球」的效果一样）。

static void FBHUDAppGoneCheck(void)
{
    static NSString *sBundlePath = nil;
    if (!sBundlePath) {
        sBundlePath = [[[NSBundle mainBundle] bundlePath] copy];
        if (sBundlePath.length == 0) {
            // 连自己从哪儿来的都解析不出来：保守直接退，别当无主的僵尸飘着。
            FBLog(@"看门狗：解析不到所属 .app 目录，直接退出");
            exit(0);
        }
        FBLog(@"看门狗：盯住 %@（摸不到就说明 App 被删了）", sBundlePath);
    }

    struct stat st;
    if (stat([sBundlePath fileSystemRepresentation], &st) == 0 && (st.st_mode & S_IFDIR)) {
        // App 还在 —— 最常见的返回，什么都不做
        return;
    }
    static int sMisses = 0;
    sMisses++;
    FBLog(@"看门狗：.app 目录摸不到了（第 %d/3 次），App 可能已删除：%@", sMisses, sBundlePath);
    if (sMisses >= 3) {
        FBLog(@"看门狗：App 已删除，悬浮球进程自杀退出（pid=%d）", getpid());
        exit(0);
    }
}

/// 挂一个后台定时器，每 3 秒查一次「App 的 .app 目录还在不在」。
/// ⚠️ 在进入 runloop 之前就挂好（这里只是注册了源，真正起跑不挑时机）。
static void FBHUDStartAppBundleWatchdog(void)
{
    static dispatch_source_t sWatchdog = nil;
    sWatchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(sWatchdog,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),  // 先等 5 秒（让球先立起来）
                              (uint64_t)(3 * NSEC_PER_SEC),   // 每 3 秒查一次
                              (uint64_t)(2 * NSEC_PER_SEC));  // 允许 2 秒的调度抖动
    dispatch_source_set_event_handler(sWatchdog, ^{
        FBHUDAppGoneCheck();
    });
    dispatch_resume(sWatchdog);
    FBLog(@"看门狗已挂上：每 3 秒确认 App 还在不在（连续 3 次摸不到 = App 被删 = 自尽）");
}

#pragma mark -

int main(int argc, char *argv[])
{
    @autoreleasepool
    {
#if DEBUG
        os_log_debug(OS_LOG_DEFAULT, "launched argc %{public}d, argv[1] %{public}s", argc, argc > 1 ? argv[1] : "NULL");
#endif

        if (argc <= 1)
            return UIApplicationMain(argc, argv, @"MainApplication", @"MainApplicationDelegate");

        if (strcmp(argv[1], "-hud") == 0)
        {
            FBLog(@"=== HUD 进程启动 pid=%d uid=%u ===", getpid(), (unsigned int)getuid());
            pid_t pid = getpid();
            NSString *pidString = [NSString stringWithFormat:@"%d", pid];
            [pidString writeToFile:FBHUDPIDFilePath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
            // ⚠️ 显式给 0644：球是 root（umask 022 时本来也是 644），但万一 umask 是 077，
            //    App（uid 501）就读不到这个文件了 —— 那开关会一直显示「没在跑」。
            chmod(FBHUDPIDFilePath().UTF8String, 0644);
            FBLog(@"pid 文件写到 %@", FBHUDPIDFilePath());
            // 正常退出时把 pid 文件带走（App 就是靠「文件在 + 进程在」判断球在不在跑）。
            // ⚠️ 被 SIGKILL 杀掉时 atexit 不会执行 —— 那种情况下由 -exit 自己 unlink（见下）。
            atexit(FBHUDUnlinkPIDFile);

            // ⚠️ 0.1.12 看门狗：App 被删了，球要跟着自尽。
            //    复现（用户 2026-10-17 报的）：把悬浮球 App 删了，屏幕上的球还在 ——
            //    球是 root 的独立进程，删 App 只是把 .app 目录拆掉，正在跑的进程没人管，
            //    原来又没人写过「App 不在了就退」这条规矩，于是球成僵尸（只能重启才能清）。
            FBHUDStartAppBundleWatchdog();

            // 不走 SpringBoard，自己把 UIKit 支起来
            [UIScreen initialize];
            CFRunLoopGetCurrent();

            GSInitialize();
            BKSDisplayServicesStart();
            UIApplicationInitialize();

            UIApplicationInstantiateSingleton(objc_getClass("HUDMainApplication"));
            static id<UIApplicationDelegate> appDelegate = [[objc_getClass("HUDMainApplicationDelegate") alloc] init];
            [UIApplication.sharedApplication setDelegate:appDelegate];
            [UIApplication.sharedApplication _accessibilityInit];

            [NSRunLoop currentRunLoop];

#if USE_HID_EVENT_CALLBACK
            // ⚠️ 顺序要紧：**先把 HID 那套符号加载好，再注册回调**。
            //    dlopen 绝不能出现在回调里 —— 那是 backboardd 的事件线程，
            //    在那儿做加载有把回调卡死的风险（0.1.5 的教训：球直接穿透、不响应）。
            FBPrepareHID();

            // 路A：BKS 回调。0.1.3~0.1.6 只有它，真机实测一条事件都收不到
            //     （0.1.6 自检：回调=0，按音量键也不涨）；先留着继续计数。
            void *bksClient = BKSHIDEventRegisterEventCallback(_HUDEventCallback);
            FBLog(@"路A：BKS 回调已注册，返回=%p", bksClient);

            // 路B：IOHIDEventSystemClient 监视客户端（0.1.7 新加，有据可查的那条路）
            FBStartHIDMonitor();

            // 万一路A 返回的真是个事件系统客户端，就替它匹配 + 挂 runloop
            FBMaybeScheduleBKSRoute(bksClient);

            FBProbeWrite(YES);   // 先落一份「全是 0」的，好区分「回调没来过」和「球进程没起来」
            FBLog(@"触摸自检文件：%@（App 的「关于」页会读它）", FB_PROBE_PATH);
#endif

            if (@available(iOS 15.0, *)) {
                GSEventInitialize(0);
                GSEventPushRunLoopMode(kCFRunLoopDefaultMode);
            }

            [UIApplication.sharedApplication __completeAndRunAsPlugin];

            // SpringBoard 重启（respring/重启）之后，球跟着重建
            static int springBoardBootToken;
            notify_register_dispatch("SBSpringBoardDidLaunchNotification", &springBoardBootToken,
                                     dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0l), ^(int token) {
                notify_cancel(token);
                SetHUDEnabled(YES);
#ifdef NOTIFY_DISMISSAL_HUD
                notify_post(NOTIFY_DISMISSAL_HUD);
#endif
                kill(pid, SIGKILL);
            });

            CFRunLoopRun();
            FBLog(@"HUD runloop 已退出（不该发生）");
            return EXIT_SUCCESS;
        }
        else if (strcmp(argv[1], "-exit") == 0)
        {
            NSString *pidString = [NSString stringWithContentsOfFile:FBHUDPIDFilePath() encoding:NSUTF8StringEncoding error:nil];
            FBLog(@"-exit 收到，pid 文件内容 = %@", pidString);
            if (pidString)
            {
                pid_t pid = (pid_t)[pidString intValue];
                if (pid > 0) kill(pid, SIGKILL);
                // ⚠️ 只在「文件里记的还是这个 pid」时才删：用户关掉又马上打开时，
                //    新的球可能已经把新 pid 写进去了 —— 那把文件删掉会让 App 以为球没跑。
                NSString *now = [NSString stringWithContentsOfFile:FBHUDPIDFilePath()
                                                          encoding:NSUTF8StringEncoding
                                                             error:nil];
                if (now && [now isEqualToString:pidString]) FBHUDUnlinkPIDFile();
            }
            else
            {
                // 读不到内容：文件可能是个空壳/过期了，直接删掉
                FBHUDUnlinkPIDFile();
            }
            return EXIT_SUCCESS;
        }
        else if (strcmp(argv[1], "-check") == 0)
        {
            // ⚠️ 0.1.11 起 App 不再 spawn 这个分支来判断状态了（太慢，见 HUDHelper.mm）。
            //    留着只为手动排查用：`./FloatingBall -check`，退出码 0 = 没跑、非 0 = 在跑。
            NSString *pidString = [NSString stringWithContentsOfFile:FBHUDPIDFilePath() encoding:NSUTF8StringEncoding error:nil];
            if (pidString)
            {
                pid_t pid = (pid_t)[pidString intValue];
                int killed = kill(pid, 0);
                return (killed == 0 || errno == EPERM) ? EXIT_FAILURE : EXIT_SUCCESS;
            }
            else return EXIT_SUCCESS;  // 没有 pid 文件 = 球没在跑
        }
    }
}
