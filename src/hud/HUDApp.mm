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
#import <dlfcn.h>

#import "HUDHelper.h"
#import "FBLog.h"
#import "FBSystemActions.h"

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
// ============================================================================
#define FB_PROBE_PATH   @"/tmp/FloatingBall.probe"

static int    sProbeCallbacks = 0;   // ① 回调进来了几次（两条路合计）
static int    sProbeRouteA    = 0;   // ① 其中来自「BKS 回调」那条路的
static int    sProbeRouteB    = 0;   // ① 其中来自「监视客户端」那条路的
static int    sProbeMatched   = -1;  // 监视客户端按 13/4 匹配到几个触摸屏服务（-1 = 没问）
static int    sProbeNoRep     = 0;   // ② rep 转不出来
static int    sProbeNoPath    = 0;   // ③ 没有手指路径（按键 / 父事件都走这里）
static int    sProbeZeroID    = 0;   // ③ pathIdentity<=0（当 1 用了）
static int    sProbeNotOurs   = 0;   // ④ 不是我们接管的那个触点
static int    sProbeOffBall   = 0;   // ④ 按下不在球上
static int    sProbeOtherRoute = 0;  // 另一条路又送来的触摸（只记数，不喂，防重复）
static int    sProbeTakeover  = 0;   // ⑤ 接管了
static int    sProbeFed       = 0;   // ⑤ 喂给球视图了
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

/// 活跃的触摸来源：0 = 还没定，1 = 路A（BKS 回调），2 = 路B（监视客户端）
static int gHIDActiveRoute = 0;

static void FBProbeWrite(BOOL force)
{
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!force && now - sProbeLastWrite < 1.0) return;
    sProbeLastWrite = now;
    NSString *text = [NSString stringWithFormat:
        @"回调=%d（路A=%d 路B=%d 匹配服务=%d） 无rep=%d 无路径=%d id<=0=%d "
        @"不在球=%d 非本触点=%d 另一条路=%d 接管=%d 喂球=%d\n"
        @"真触摸：窗口问=%d 落在球=%d 真点击=%d\n最后：%@\n",
        sProbeCallbacks, sProbeRouteA, sProbeRouteB, sProbeMatched,
        sProbeNoRep, sProbeNoPath, sProbeZeroID,
        sProbeOffBall, sProbeNotOurs, sProbeOtherRoute, sProbeTakeover, sProbeFed,
        sProbeHitAsk, sProbeHitBall, sProbeRealTap, sProbeLast];
    [text writeToFile:FB_PROBE_PATH atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static void FBProbeNote(NSString *reason)
{
    sProbeLast = reason;
    FBProbeWrite(NO);
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
    if (sProbeRealTap == 1) FBLog(@"真触摸：球自己的单击手势触发了");
    FBProbeWrite(NO);
}

/// 真触摸这条路是不是已经通了？通了就别再喂合成触摸（否则一次点击走两遍）。
BOOL FBRealTouchWorks(void)
{
    return sProbeHitBall > 0 || sProbeRealTap > 0;
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

    // 0.1.8：如果「真触摸」那条路（窗口参与命中测试）已经通了，
    // 就**不再**喂合成触摸 —— 否则一次点击会被处理两遍（手势 + 假触摸），
    // 表现就是「点一下算两下」。这两条路是二选一的备份关系。
    if (FBRealTouchWorks()) return;

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

    BOOL isDown = [rep isTouchDown];
    CGPoint onScreen = [rep location];        // 全局（屏幕）坐标

    // 头 3 条事件原样记一笔：能看出「到底有没有触摸事件进来、长什么样」
    if (sProbeCallbacks <= 3) {
        FBLog(@"HID#%d etype=%d paths=%lu id=%ld down=%d move=%d lift=%d 点=(%.0f,%.0f)",
              sProbeCallbacks, FBHIDEventTypeOf(event), (unsigned long)paths.count, (long)pointerId,
              (int)isDown, (int)[rep isMove], (int)[rep isLift], onScreen.x, onScreen.y);
    }

    UITouchPhase phase = UITouchPhaseEnded;
    if (isDown)                  phase = UITouchPhaseBegan;
    else if ([rep isMove])       phase = UITouchPhaseMoved;
    else if ([rep isCancel])     phase = UITouchPhaseCancelled;
    else if ([rep isLift] || [rep isInRange] || [rep isInRangeLift]) phase = UITouchPhaseEnded;

    dispatch_async(dispatch_get_main_queue(), ^(void) {
        UIView *ball = gFBBallView;
        UIWindow *window = ball.window;
        if (!ball || !window) {
            FBProbeNote(@"⑤ 球视图还没就绪（ball / window 是空的）");
            return;
        }

        // 球在屏幕上的矩形（含 6pt 宽容区）。
        // ⚠️ 这里刻意**不用 hitTest**：窗口的 _ignoresHitTest 是 YES（为了绝不吃掉系统触摸），
        //    那样对窗口 hitTest 永远回 nil。直接量矩形，不依赖坐标系约定，最不容易出错。
        CGRect inWindowRect = [ball convertRect:ball.bounds toView:window];
        CGRect onScreenRect = CGRectOffset(inWindowRect, window.frame.origin.x, window.frame.origin.y);
        BOOL onBall = CGRectContainsPoint(CGRectInset(onScreenRect, -6.0, -6.0), onScreen);

        if (isDown) {
            if (!onBall) {
                // 按在别处：不插手，完全留给下面的 App（这是设计如此，不是 bug）
                sProbeOffBall++;
                FBProbeNote([NSString stringWithFormat:@"④ 按在球外（点=(%.0f,%.0f) 球=%@）",
                             onScreen.x, onScreen.y, NSStringFromCGRect(onScreenRect)]);
                return;
            }
            sProbeTakeover++;
            FBProbeNote([NSString stringWithFormat:@"⑤ 接管了（id=%ld 点=(%.0f,%.0f) 球=%@）",
                         (long)pointerId, onScreen.x, onScreen.y, NSStringFromCGRect(onScreenRect)]);
            gFBActivePointer = pointerId;
            FBLog(@"触摸：按下落在球上（屏幕 %.0f,%.0f）→ 接管触点 %ld",
                  onScreen.x, onScreen.y, (long)pointerId);
        } else if (gFBActivePointer != pointerId) {
            // 不是我们接管的触点，别插手。
            // ⚠️ 如果「按下」那条从来没进到上面那个分支（比如 isTouchDown 一直是 0），
            //    就会一直掉到这里 —— 所以也记一笔，别让它静默。
            sProbeNotOurs++;
            FBProbeNote([NSString stringWithFormat:@"④ 不是本触点（id=%ld down=%d move=%d lift=%d 点=(%.0f,%.0f)）",
                         (long)pointerId, (int)isDown, (int)[rep isMove], (int)[rep isLift],
                         onScreen.x, onScreen.y]);
            return;
        }

        CGPoint inWindow = CGPointMake(onScreen.x - window.frame.origin.x,
                                       onScreen.y - window.frame.origin.y);

        // ⚠️ atGlobalCoordinate 这个参数名是骗人的：TSEventFetcher 内部直接
        //    `setLocationInWindow:`，所以必须传**窗口坐标**，不能传屏幕坐标。
        //    （Helium 的窗口是全屏的，两种坐标正好一样，照抄会踩坑。）
        [TSEventFetcher receiveAXEventID:pointerId
                      atGlobalCoordinate:inWindow
                          withTouchPhase:phase
                                inWindow:window
                                  onView:ball];
        sProbeFed++;
        FBProbeWrite(NO);

        if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
            if (gFBActivePointer == pointerId) {
                gFBActivePointer = 0;
                FBLog(@"触摸：触点 %ld 抬起/取消，交还", (long)pointerId);
            }
        }
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

static NSString *_hudPIDFilePath = nil;
static NSString *GetPIDFilePath(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        _hudPIDFilePath = [caches stringByAppendingPathComponent:@"hud.pid"];
    });
    return _hudPIDFilePath;
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
            [pidString writeToFile:GetPIDFilePath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
            FBLog(@"pid 文件写到 %@", GetPIDFilePath());

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
            NSString *pidString = [NSString stringWithContentsOfFile:GetPIDFilePath() encoding:NSUTF8StringEncoding error:nil];
            FBLog(@"-exit 收到，pid 文件内容 = %@", pidString);
            if (pidString)
            {
                pid_t pid = (pid_t)[pidString intValue];
                kill(pid, SIGKILL);
                unlink(GetPIDFilePath().UTF8String);
            }
            return EXIT_SUCCESS;
        }
        else if (strcmp(argv[1], "-check") == 0)
        {
            NSString *pidString = [NSString stringWithContentsOfFile:GetPIDFilePath() encoding:NSUTF8StringEncoding error:nil];
            if (pidString)
            {
                pid_t pid = (pid_t)[pidString intValue];
                int killed = kill(pid, 0);
                return (killed == 0 ? EXIT_FAILURE : EXIT_SUCCESS);
            }
            else return EXIT_SUCCESS;  // 没有 pid 文件 = 球没在跑
        }
    }
}
