//
//  SwiftObjCPPBridger.m
//
//  Swift 够不着的 ObjC/C 函数，从这里过一手。
//

#import "SwiftObjCPPBridger.h"
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../hud/FBLog.h"

#pragma mark - HUD Functions

extern BOOL IsHUDEnabled(void);
extern void SetHUDEnabled(BOOL isEnabled);
extern void waitForNotification(void (^onFinish)(), BOOL isEnabled);

BOOL IsHUDEnabledBridger(void)
{
    return IsHUDEnabled();
}

void SetHUDEnabledBridger(BOOL isEnabled)
{
    // 每次「开球」都重开一份日志：这一次尝试的全过程才是我们要看的
    if (isEnabled) {
        FBLogReset();
        FBLog(@"=== App 请求启动悬浮球 ===");
    } else {
        FBLog(@"=== App 请求关闭悬浮球 ===");
    }

    SetHUDEnabled(isEnabled);
}

void waitForNotificationBridger(void (^onFinish)(), BOOL isEnabled)
{
    waitForNotification(onFinish, isEnabled);
}

#pragma mark - Notifications

void FBPostNotify(const char *name)
{
    if (name) notify_post(name);
}

// 与 hud-prefix.pch 的 NOTIFY_RELOAD_HUD 保持一致
NSString *const FBNotifyReloadHUD = @NOTIFY_RELOAD_HUD;

#pragma mark - 已安装的 App 列表

NSArray<NSDictionary<NSString *, NSString *> *> *FBInstalledApps(void)
{
    // 私有类一律走字符串（见 FBSystemActions.mm 里的说明）：
    // 直接写类名会让链接期去解析符号，objc_getClass 只是个查找。
    Class wsClass = objc_getClass("LSApplicationWorkspace");
    if (!wsClass) return @[];

    id ws = [(id)wsClass performSelector:@selector(defaultWorkspace)];
    SEL listSel = NSSelectorFromString(@"allInstalledApplications");
    if (!ws || ![ws respondsToSelector:listSel]) return @[];

    NSArray *apps = ((id (*)(id, SEL))objc_msgSend)(ws, listSel);
    if (![apps isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray *out = [NSMutableArray array];
    for (id proxy in apps) {
        NSString *bid  = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"applicationIdentifier"));
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"localizedName"));
        if (![bid isKindOfClass:[NSString class]] || bid.length == 0) continue;
        if (![name isKindOfClass:[NSString class]] || name.length == 0) continue;
        [out addObject:@{ @"id": bid, @"name": name }];
    }

    return [out sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCompare:b[@"name"]];
    }];
}
