//
//  FBSystemActions.mm
//
//  见同目录 FBSystemActions.h 的说明。
//
//  ⚠️ 这个文件是 **ObjC++**（.mm），跨 .m/.swift 用的 C 函数在头文件里必须包
//     extern "C"，否则符号会被 C++ 修饰名，链接期 undefined symbols。
//     （这个坑在 FBLog 上已经踩过一次。）
//

#import "FBSystemActions.h"
#import "FBLog.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 刷新蜂窝网络信号

BOOL FBRefreshCellularSignal(void)
{
    // ---- 1) 拿 CoreTelephony 的句柄 ----
    // 为什么不是 #import <CoreTelephony/CTServerConnection.h> 然后直接调：
    //   那是私有符号，直接调用会让**链接期**去找它，找不到就是 undefined symbol；
    //   dlsym 找不到只是返回 NULL，最坏情况是「点了没反应」，不是编译不过。
    static void *handle = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony",
                        RTLD_NOW);
        if (!handle) {
            FBLog(@"⚠️ 打不开 CoreTelephony：%s", dlerror() ?: "?");
        }
    });
    if (!handle) return NO;

    // ---- 2) 取那两个私有函数 ----
    // _CTServerConnectionCreate(allocator, callback, context)  —— 后两个可以给 NULL
    // _CTServerConnectionResetModem(connection, reason)
    typedef void *(*FBCreateFn)(CFAllocatorRef, void *, void *);
    typedef void  (*FBResetFn)(void *, CFStringRef);

    static FBCreateFn create = NULL;
    static FBResetFn  reset  = NULL;
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{
        create = (FBCreateFn)dlsym(handle, "_CTServerConnectionCreate");
        reset  = (FBResetFn)dlsym(handle, "_CTServerConnectionResetModem");
    });

    if (!create || !reset) {
        FBLog(@"⚠️ 这个系统上找不到 _CTServerConnectionCreate / _CTServerConnectionResetModem，"
              @"刷新信号做不了（系统版本太老或太新都可能）");
        return NO;
    }

    // ---- 3) 建连接（建一次就缓存着，跟 TrollSIMSwitcher 一样）----
    static void *conn = NULL;
    if (!conn) {
        conn = create(kCFAllocatorDefault, NULL, NULL);
    }
    if (!conn) {
        FBLog(@"⚠️ _CTServerConnectionCreate 返回空，连不上 CommCenter");
        return NO;
    }

    // ---- 4) 发请求 ----
    // reason 用 "UserTriggeredReload"（和 TrollSIMSwitcher 一致）。
    // ⚠️ 之后就没有下文了：没有回调、没有返回值告诉我们成没成。
    reset(conn, CFSTR("UserTriggeredReload"));
    FBLog(@"已请求重置基带（刷新蜂窝信号）。⚠️ 这 API 没有结果，成没成看状态栏信号格");
    return YES;
}

#pragma mark - 打开 App

BOOL FBOpenApplication(NSString *bundleID)
{
    if (bundleID.length == 0) return NO;

    // ⚠️ 故意不写 [LSApplicationWorkspace defaultWorkspace]：
    //    写类名会让链接期要求解析私有 framework 的类符号；
    //    objc_getClass 只是个字符串查找，永远不会链接失败。
    Class wsClass = objc_getClass("LSApplicationWorkspace");
    if (wsClass) {
        id ws = [(id)wsClass performSelector:@selector(defaultWorkspace)];
        SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (ws && [ws respondsToSelector:openSel]) {
            // ⚠️ 必须 objc_msgSend + 显式函数指针，不能写 performSelector：
            //    performSelector 的返回类型是 id，ARC 会把 BOOL 的 0x1 当对象 retain → 崩。
            BOOL (*openApp)(id, SEL, NSString *) = (BOOL (*)(id, SEL, NSString *))objc_msgSend;
            if (openApp(ws, openSel, bundleID)) return YES;
        }
    }

    // 兜底：SpringBoardServices 的 C 接口（TheBall 用的就是这条路）。
    typedef int (*SBSLaunchFn)(NSString *, NSDictionary *, NSDictionary *, BOOL);
    static SBSLaunchFn launchFn = NULL;
    static dispatch_once_t launchOnce;
    dispatch_once(&launchOnce, ^{
        launchFn = (SBSLaunchFn)dlsym(RTLD_DEFAULT,
                                      "SBSLaunchApplicationWithIdentifierAndLaunchOptions");
    });

    if (launchFn) {
        int rc = launchFn(bundleID, @{}, @{}, NO);
        if (rc != 0) {
            FBLog(@"打开 %@ 失败（SBS 兜底那条路），rc=%d", bundleID, rc);
        }
        return rc == 0;
    }

    FBLog(@"⚠️ 两条路都走不通，打不开 %@", bundleID);
    return NO;
}
