#import "MainApplicationDelegate.h"
#import "MainApplication.h"
#import "FloatingBall-Swift.h"

@implementation MainApplicationDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary <UIApplicationLaunchOptionsKey, id> *)launchOptions
{
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    [self.window setRootViewController:[[[BallInterface alloc] init] createUI]];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
