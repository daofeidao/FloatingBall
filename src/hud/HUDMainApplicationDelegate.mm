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

    // ⚠️ 顺序有讲究：initialCenter 会先把共享设置读进来，
    //    必须排在 windowSide 前面，否则球尺寸会一直是默认值。
    CGPoint center = [_rootViewController initialCenter];
    CGFloat side = [_rootViewController windowSide];
    FBLog(@"准备建窗口：球尺寸=%.0f 窗口边长=%.0f 初始球心=(%.0f, %.0f)",
          [_rootViewController ballSize], side, center.x, center.y);

    self.window = [[HUDMainWindow alloc] initWithFrame:CGRectMake(center.x - side / 2.0,
                                                                  center.y - side / 2.0,
                                                                  side, side)];
    // 球周围留了一圈余量（给阴影和手指宽容区），那圈必须是透明的，
    // 否则窗口不透明会把余量画成黑块。
    [self.window setBackgroundColor:[UIColor clearColor]];
    [self.window setOpaque:NO];
    [self.window setRootViewController:_rootViewController];
    [self.window setWindowLevel:10000010.0];
    [self.window setHidden:NO];
    [self.window makeKeyAndVisible];

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
