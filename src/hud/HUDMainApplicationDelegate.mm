#import <objc/runtime.h>

#import "HUDMainApplicationDelegate.h"
#import "HUDMainWindow.h"
#import "BallRootViewController.h"
#import "FBLog.h"

#import "../helpers/private_headers/SBSAccessibilityWindowHostingController.h"
#import "../helpers/private_headers/UIWindow+Private.h"

@implementation HUDMainApplicationDelegate {
    BallRootViewController *_rootViewController;
    SBSAccessibilityWindowHostingController *_windowHostingController;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary <UIApplicationLaunchOptionsKey, id> *)launchOptions
{
    _rootViewController = [[BallRootViewController alloc] init];

    // ⚠️⚠️ 0.1.18：窗口改成**全屏**（照抄 TheBall 2.7：它用 [UIScreen mainScreen].bounds）。
    //   以前我们把窗口做成「只有球那么大」，球靠移动窗口来动 —— 那样系统根本不会把
    //   触摸送进来（真机「窗口问=0」）。现在球是**全屏窗口里的一个子视图**，
    //   窗口的 hitTest 只认子视图、球以外返回 nil，触摸照样漏给下面的 App。
    CGRect screen = [UIScreen mainScreen].bounds;
    self.window = [[HUDMainWindow alloc] initWithFrame:screen];
    // 球以外那圈必须是透明的，否则全屏窗口会盖成一块黑。
    [self.window setBackgroundColor:[UIColor clearColor]];
    [self.window setOpaque:NO];
    [self.window setRootViewController:_rootViewController];
    [self.window setWindowLevel:10000010.0];
    [self.window setHidden:NO];
    [self.window makeKeyAndVisible];

    FBLog(@"准备建窗口：全屏 %@，球直径=%.0f 初始球心=(%.0f, %.0f)",
          NSStringFromCGRect(screen), [_rootViewController ballSize],
          [_rootViewController initialCenter].x, [_rootViewController initialCenter].y);

    // 把窗口注册到 SpringBoard（这一步才是「浮在所有 App 之上」的真身）
    _windowHostingController = [[objc_getClass("SBSAccessibilityWindowHostingController") alloc] init];
    unsigned int contextId = [self.window _contextId];
    double windowLevel = [self.window windowLevel];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    // 用 NSInvocation 而不是直接调用：私有方法在编译期没有声明
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:_windowHostingController];
    [invocation setSelector:NSSelectorFromString(@"registerWindowWithContextID:atLevel:")];
    [invocation setArgument:&contextId atIndex:2];
    [invocation setArgument:&windowLevel atIndex:3];
    [invocation invoke];
#pragma clang diagnostic pop

    FBLog(@"窗口已建：frame=%@ level=%.0f contextId=%u，已向 SpringBoard 注册",
          NSStringFromCGRect(self.window.frame), windowLevel, contextId);

    return YES;
}

@end
