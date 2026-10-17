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

static __used
void _HUDEventCallback(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event)
{
    static UIApplication *app = [UIApplication sharedApplication];
#if DEBUG
    os_log_debug(OS_LOG_DEFAULT, "_HUDEventCallback => %{public}@", event);
#endif

    // 顺手把真机的 sender ID 学下来：注入触摸（全局返回）必须用它。
    // 放在最前面 —— 下面有好几条早退分支，不管走哪条都先把这条记下来。
    FBHIDNoteRealEvent(event);

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
    if (!rep) return;

    NSInteger pointerId = [[[[rep handInfo] paths] firstObject] pathIdentity];
    if (pointerId <= 0) return;
    pointerId = MIN(MAX(pointerId, 1), 98);   // TSEventFetcher 一共 100 个槽位

    BOOL isDown = [rep isTouchDown];
    CGPoint onScreen = [rep location];        // 全局（屏幕）坐标

    UITouchPhase phase = UITouchPhaseEnded;
    if (isDown)                  phase = UITouchPhaseBegan;
    else if ([rep isMove])       phase = UITouchPhaseMoved;
    else if ([rep isCancel])     phase = UITouchPhaseCancelled;
    else if ([rep isLift] || [rep isInRange] || [rep isInRangeLift]) phase = UITouchPhaseEnded;

    dispatch_async(dispatch_get_main_queue(), ^(void) {
        UIView *ball = gFBBallView;
        UIWindow *window = ball.window;
        if (!ball || !window) return;

        // 球在屏幕上的矩形（含 6pt 宽容区）。
        // ⚠️ 这里刻意**不用 hitTest**：窗口的 _ignoresHitTest 是 YES（为了绝不吃掉系统触摸），
        //    那样对窗口 hitTest 永远回 nil。直接量矩形，不依赖坐标系约定，最不容易出错。
        CGRect inWindowRect = [ball convertRect:ball.bounds toView:window];
        CGRect onScreenRect = CGRectOffset(inWindowRect, window.frame.origin.x, window.frame.origin.y);
        BOOL onBall = CGRectContainsPoint(CGRectInset(onScreenRect, -6.0, -6.0), onScreen);

        if (isDown) {
            if (!onBall) return;     // 按在别处：不插手，完全留给下面的 App
            gFBActivePointer = pointerId;
            FBLog(@"触摸：按下落在球上（屏幕 %.0f,%.0f）→ 接管触点 %ld",
                  onScreen.x, onScreen.y, (long)pointerId);
        } else if (gFBActivePointer != pointerId) {
            return;                  // 不是我们接管的触点，别插手
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

        if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
            if (gFBActivePointer == pointerId) {
                gFBActivePointer = 0;
                FBLog(@"触摸：触点 %ld 抬起/取消，交还", (long)pointerId);
            }
        }
    });
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
            BKSHIDEventRegisterEventCallback(_HUDEventCallback);
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
