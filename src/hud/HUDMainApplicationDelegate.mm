#import <objc/runtime.h>

#import "HUDMainApplicationDelegate.h"
#import "HUDMainWindow.h"
#import "BallRootViewController.h"

#import "../helpers/private_headers/SBSAccessibilityWindowHostingController.h"
#import "../helpers/private_headers/UIWindow+Private.h"

@implementation HUDMainApplicationDelegate {
    BallRootViewController *_rootViewController;
    SBSAccessibilityWindowHostingController *_windowHostingController;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary <UIApplicationLaunchOptionsKey, id> *)launchOptions
{
    _rootViewController = [[BallRootViewController alloc] init];

    CGFloat side = [_rootViewController windowSide];
    CGPoint center = [_rootViewController initialCenter];

    self.window = [[HUDMainWindow alloc] initWithFrame:CGRectMake(center.x - side / 2.0,
                                                                  center.y - side / 2.0,
                                                                  side, side)];
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

    return YES;
}

@end
