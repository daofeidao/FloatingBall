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

#pragma mark - 0.1.47：App 的 URL schemes

NSArray<NSString *> *FBAppURLSchemes(NSString *bundleID)
{
    if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) return @[];

    Class wsClass = objc_getClass("LSApplicationWorkspace");
    if (!wsClass) return @[];
    id ws = [(id)wsClass performSelector:@selector(defaultWorkspace)];
    if (!ws) return @[];

    // ① 按 bundleID 直接拿 proxy
    id proxy = nil;
    SEL byId = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if ([ws respondsToSelector:byId]) {
        proxy = ((id (*)(id, SEL, NSString *))objc_msgSend)(ws, byId, bundleID);
    }
    // ② 退路：遍历已安装列表按 applicationIdentifier 匹配
    if (!proxy) {
        SEL listSel = NSSelectorFromString(@"allInstalledApplications");
        if ([ws respondsToSelector:listSel]) {
            NSArray *all = ((id (*)(id, SEL))objc_msgSend)(ws, listSel);
            if ([all isKindOfClass:[NSArray class]]) {
                SEL idSel = NSSelectorFromString(@"applicationIdentifier");
                for (id p in all) {
                    NSString *bid = ((id (*)(id, SEL))objc_msgSend)(p, idSel);
                    if ([bid isKindOfClass:[NSString class]] && [bid isEqualToString:bundleID]) {
                        proxy = p;
                        break;
                    }
                }
            }
        }
    }
    if (!proxy) return @[];

    // ③ 读它自己的 Info.plist（App 有 no-sandbox，bundle 目录读得到）
    NSURL *bundleURL = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"bundleURL"));
    if (![bundleURL isKindOfClass:[NSURL class]]) return @[];

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:
                          [bundleURL URLByAppendingPathComponent:@"Info.plist"]];
    NSArray *types = info[@"CFBundleURLTypes"];
    if (![types isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id t in types) {
        if (![t isKindOfClass:[NSDictionary class]]) continue;
        NSArray *schemes = ((NSDictionary *)t)[@"CFBundleURLSchemes"];
        if (![schemes isKindOfClass:[NSArray class]]) continue;
        for (id s in schemes) {
            if (![s isKindOfClass:[NSString class]] || [s length] == 0) continue;
            if (![out containsObject:s]) [out addObject:s];
        }
    }
    return out;
}
