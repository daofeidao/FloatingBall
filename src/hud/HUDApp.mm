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

#import "../helpers/ts/TSEventFetcher.h"
#import "../helpers/private_headers/AXEventRepresentation.h"
#import "../helpers/private_headers/BackboardServices.h"
#import "../helpers/private_headers/UIApplication+Private.h"

// ============================================================================
// v0.1 用「小窗口直接吃触摸」这条路（HUDMainWindow._ignoresHitTest 返回 NO）。
// 这条路若不成立（球显示得出来但点不动），把下面改成 1 就切到备用路线：
// 自己监听全局 HID 事件、手动把触摸喂给自己的视图。
// ⚠️ 两条路不能同时开，否则一次点击会被处理两遍。
// ============================================================================
#define USE_HID_EVENT_CALLBACK 0

static __used
void _HUDEventCallback(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event)
{
    static UIApplication *app = [UIApplication sharedApplication];
#if DEBUG
    os_log_debug(OS_LOG_DEFAULT, "_HUDEventCallback => %{public}@", event);
#endif

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

    if (shouldUseAXEvent)
    {
        static Class AXEventRepresentationCls = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/AccessibilityUtilities.framework"] load];
            AXEventRepresentationCls = objc_getClass("AXEventRepresentation");
        });

        AXEventRepresentation *rep = [AXEventRepresentationCls representationWithHIDEvent:event hidStreamIdentifier:@"UIApplicationEvents"];

        dispatch_async(dispatch_get_main_queue(), ^(void) {
            static UIWindow *keyWindow = nil;
            static dispatch_once_t onceToken2;
            dispatch_once(&onceToken2, ^{
                keyWindow = [[app windows] firstObject];
            });

            UIView *keyView = [keyWindow hitTest:[rep location] withEvent:nil];

            UITouchPhase phase = UITouchPhaseEnded;
            if ([rep isTouchDown])      phase = UITouchPhaseBegan;
            else if ([rep isMove])      phase = UITouchPhaseMoved;
            else if ([rep isCancel])    phase = UITouchPhaseCancelled;
            else if ([rep isLift] || [rep isInRange] || [rep isInRangeLift]) phase = UITouchPhaseEnded;

            NSInteger pointerId = [[[[rep handInfo] paths] firstObject] pathIdentity];
            if (pointerId > 0)
                [TSEventFetcher receiveAXEventID:MIN(MAX(pointerId, 1), 98)
                              atGlobalCoordinate:[rep location]
                                  withTouchPhase:phase
                                        inWindow:keyWindow
                                          onView:keyView];
        });
    }
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
