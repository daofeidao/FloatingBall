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

#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <unistd.h>

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

#pragma mark - 打开 URL（URL 协议 / 系统快捷指令）

BOOL FBOpenURL(NSString *urlString)
{
    if (urlString.length == 0) return NO;

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || url.scheme.length == 0) {
        // 没 scheme 的字符串交给系统也是白搭（会被当成路径），先拦下来
        FBLog(@"⚠️ 这条算不上 URL（没 scheme）：%@", urlString);
        return NO;
    }

    // ---- ① LSApplicationWorkspace：root 进程里的正路 ----
    // 和 FBOpenApplication 一样：objc_getClass 取类名，不写类符号（不写就不会链接失败）
    Class wsClass = objc_getClass("LSApplicationWorkspace");
    id ws = wsClass ? [(id)wsClass performSelector:@selector(defaultWorkspace)] : nil;

    if (ws) {
        // 带 error 的重载：能顺便把失败原因记进日志
        SEL selErr = NSSelectorFromString(@"openURL:withOptions:error:");
        if ([ws respondsToSelector:selErr]) {
            NSError *error = nil;
            BOOL (*fn)(id, SEL, NSURL *, NSDictionary *, NSError **) =
                (BOOL (*)(id, SEL, NSURL *, NSDictionary *, NSError **))objc_msgSend;
            if (fn(ws, selErr, url, @{}, &error)) return YES;
            FBLog(@"打开 URL 没成（LSApplicationWorkspace）：%@", error.localizedDescription ?: @"没说原因");
        }

        SEL selPlain = NSSelectorFromString(@"openURL:withOptions:");
        if ([ws respondsToSelector:selPlain]) {
            BOOL (*fn)(id, SEL, NSURL *, NSDictionary *) =
                (BOOL (*)(id, SEL, NSURL *, NSDictionary *))objc_msgSend;
            if (fn(ws, selPlain, url, @{})) return YES;
        }

        // 有些 scheme 系统只从「敏感 URL」那条口子放行（这条是特权进程才有的待遇）
        SEL selSensitive = NSSelectorFromString(@"openSensitiveURL:withOptions:");
        if ([ws respondsToSelector:selSensitive]) {
            BOOL (*fn)(id, SEL, NSURL *, NSDictionary *) =
                (BOOL (*)(id, SEL, NSURL *, NSDictionary *))objc_msgSend;
            if (fn(ws, selSensitive, url, @{})) return YES;
        }
    }

    // ---- ② UIApplication：App 进程里的正路 ----
    // （HUD 进程也是 UIApplicationMain 起来的，所以两边都有这个对象）
    UIApplication *app = [UIApplication sharedApplication];
    SEL selOpen = NSSelectorFromString(@"openURL:options:completionHandler:");
    if (app && [app respondsToSelector:selOpen]) {
        void (*fn)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)) =
            (void (*)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)))objc_msgSend;
        fn(app, selOpen, url, @{}, nil);
        return YES;
    }

    FBLog(@"⚠️ 打不开 URL（三条路都不通）：%@", urlString);
    return NO;
}

#pragma mark - 全局返回（往系统里注入一次「从左缘往右划」）
// ============================================================================
// ⚠️⚠ 先读这段再改。这是全项目唯一一个能**伤到系统本身**的动作。
//
// 为什么危险：一次触摸是一串事件（按下 → 移动 → 抬起）。要是「抬起」没送出去，
//   屏幕上就卡住一个「一直按着不放的手指」：那个位置点不动、拖不动，
//   用户只能强制重启。球自己不接管的触摸最坏只是「球不灵」，绝不会这样。
//
// 三条保命写法（**别删**）：
//   ① **先把整串事件全造出来，再开始发**。只要有一个造不出来就整串放弃、一个都不发 ——
//      绝不允许出现"发了一半"的状态（那才是会卡住触摸的形态）。
//   ② 手指用 index=1 / identity=3，**和真手指分开**（真手指是 index 0）：
//      就算抬起时机算错，也只影响我们这一路，动不到用户的手。
//   ③ 发完 500ms 再补一条 up 兜底（range=0/touch=0，对真手指无影响）。
//
// 还有一条「电动门」级别的细节：**落点必须避开球自己**。
//   不然球会把自己注入的划动当成「用户在拖它」→ 球乱跑，甚至自己触发自己。
//   所以 FBGoBack 要收球的屏幕矩形，落点 y 挑一个不撞它的位置。
//
// 配方来源：ZXTouch（xuan32546/IOS13-SimulateTouch，iOS 11~14 真机在用的触摸自动化工具）
//   的 pccontrol/Touch.xm。照抄的要点：
//     · 每个事件是「父事件（hand, index 99, identity 1）+ 子事件（finger）」两层，坐标在子事件上；
//     · 坐标是**归一化 0~1**，分母是屏幕的点数（他们那边是像素/scale，等价）；
//     · 父事件上要自己填 EventMask / Range / Touch（0x23 / 1 / 1），还要置 IsDisplayIntegrated=1；
//     · ⚠️ sender ID 必须是**真机那一路的**（他们专门先监听一次真触摸把它学下来，
//       为 0 就拒绝注入）。我们照做，见 FBHIDNoteRealEvent。
//   ⚠️ 时间戳按 uint64_t 传（mach_absolute_time()）：他们那份私有头文件就是这么声明的。
//      本仓库 KIF 那份老代码用的是 AbsoluteTime 结构体写法，两套别混着抄。
// ============================================================================

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

// 字段号：IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) = 11 << 16 = 0xb0000
#define FBHIDFieldEventFlags            0x0004      // 通用 flags：置 1 → 带上 0x10 那位（built-in）
#define FBHIDFieldDigitizerEventMask    0x0b0007
#define FBHIDFieldDigitizerRange        0x0b0008
#define FBHIDFieldDigitizerTouch        0x0b0009
#define FBHIDFieldDigitizerMajorRadius  0x0b0014
#define FBHIDFieldDigitizerMinorRadius  0x0b0015
#define FBHIDFieldDigitizerDisplayInt   0x0b0019    // IsDisplayIntegrated

#define FBHIDDigitizerEventRange        (1u << 0)
#define FBHIDDigitizerEventTouch        (1u << 1)
#define FBHIDDigitizerEventPosition     (1u << 2)
#define FBHIDEventTypeDigitizer         11u

// 我们注入的手指：index 0 留给真手指，我们用 1；identity 固定 3
#define FBHIDInjectFingerIndex          1u
#define FBHIDInjectFingerIdentity       3u

typedef IOHIDEventRef (*FBCreateDigitizerEventFn)(CFAllocatorRef, uint64_t,
                                                  uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                                                  double, double, double, double, double,
                                                  Boolean, Boolean, uint32_t);
typedef IOHIDEventRef (*FBCreateFingerEventFn)(CFAllocatorRef, uint64_t,
                                               uint32_t, uint32_t, uint32_t,
                                               double, double, double, double, double,
                                               Boolean, Boolean, uint32_t);
typedef IOHIDEventRef (*FBCreateKeyboardEventFn)(CFAllocatorRef, uint64_t,
                                                 uint32_t, uint32_t, Boolean, uint32_t);
typedef void (*FBAppendEventFn)(IOHIDEventRef, IOHIDEventRef);
typedef void (*FBSetIntFn)(IOHIDEventRef, uint32_t, int);
typedef void (*FBSetFloatFn)(IOHIDEventRef, uint32_t, double);
typedef IOHIDEventSystemClientRef (*FBCreateHIDClientFn)(CFAllocatorRef);
typedef void (*FBDispatchHIDEventFn)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef void (*FBSetSenderIDFn)(IOHIDEventRef, uint64_t);
typedef uint32_t (*FBGetEventTypeFn)(IOHIDEventRef);
typedef uint64_t (*FBGetSenderIDFn)(IOHIDEventRef);
typedef int (*FBGetIntValueFn)(IOHIDEventRef, uint32_t);

static FBCreateDigitizerEventFn fbCreateDigitizerEvent = NULL;
static FBCreateFingerEventFn    fbCreateFingerEvent    = NULL;
static FBCreateKeyboardEventFn  fbCreateKeyboardEvent  = NULL;   // 【截屏】注入按键要用
static FBAppendEventFn          fbAppendEvent          = NULL;
static FBSetIntFn               fbSetInt               = NULL;
static FBSetFloatFn             fbSetFloat             = NULL;
static FBCreateHIDClientFn      fbCreateHIDClient      = NULL;
static FBDispatchHIDEventFn     fbDispatchHIDEvent     = NULL;
static FBSetSenderIDFn          fbSetSenderID          = NULL;
static FBGetEventTypeFn         fbGetEventType         = NULL;
static FBGetSenderIDFn          fbGetSenderID          = NULL;
static FBGetIntValueFn          fbGetIntegerValue      = NULL;   // 读事件字段（触摸自检要靠它）

static IOHIDEventSystemClientRef fbHIDClient = NULL;

/// 真机那一路的 sender ID（学到才敢注入；见 FBHIDNoteRealEvent）
static uint64_t gFBRealSenderID = 0;

/// HID 这一套符号有没有准备好（由 FBPrepareHID 置位；回调里只看这个，不做加载）
static BOOL gFBHIDReady = NO;

/// 冷却：这个时刻之前不再注入（防手抖连点 / 两个手势撞一起）
static NSTimeInterval gFBInjectCooldownUntil = 0;

/// 取一个符号：先看本进程里有没有（Makefile 里已经链了 IOKit），再退回单独 dlopen 的那份
static void *FBSymIn(void *handle, const char *name)
{
    void *p = dlsym(RTLD_DEFAULT, name);
    return p ? p : (handle ? dlsym(handle, name) : NULL);
}

static BOOL FBLoadHID(void)
{
    static BOOL loaded = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 两条路都试，别只赌一条（App 进程和 HUD 进程加载到的东西不完全一样）
        void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!handle) {
            FBLog(@"⚠️ 打不开 IOKit：%s（下面先指望进程里已有的那份）", dlerror() ?: "?");
        }

        fbCreateDigitizerEvent = (FBCreateDigitizerEventFn)FBSymIn(handle, "IOHIDEventCreateDigitizerEvent");
        fbCreateFingerEvent    = (FBCreateFingerEventFn)FBSymIn(handle, "IOHIDEventCreateDigitizerFingerEvent");
        // 按键事件（【截屏】那条兜底路要用）。⚠️ 不放进下面的 ok 判断：
        // 它取不到只影响「截屏」，不该把「全局返回」一起拖死。
        fbCreateKeyboardEvent  = (FBCreateKeyboardEventFn)FBSymIn(handle, "IOHIDEventCreateKeyboardEvent");
        fbAppendEvent          = (FBAppendEventFn)FBSymIn(handle, "IOHIDEventAppendEvent");
        fbSetInt               = (FBSetIntFn)FBSymIn(handle, "IOHIDEventSetIntegerValue");
        fbSetFloat             = (FBSetFloatFn)FBSymIn(handle, "IOHIDEventSetFloatValue");
        fbCreateHIDClient      = (FBCreateHIDClientFn)FBSymIn(handle, "IOHIDEventSystemClientCreate");
        fbDispatchHIDEvent     = (FBDispatchHIDEventFn)FBSymIn(handle, "IOHIDEventSystemClientDispatchEvent");
        fbSetSenderID          = (FBSetSenderIDFn)FBSymIn(handle, "IOHIDEventSetSenderID");
        fbGetEventType         = (FBGetEventTypeFn)FBSymIn(handle, "IOHIDEventGetType");
        fbGetSenderID          = (FBGetSenderIDFn)FBSymIn(handle, "IOHIDEventGetSenderID");
        // ⚠️ 和按键事件一样**不放进下面的 ok 判断**：它取不到只影响「触摸自检」，
        //    不该把「全局返回 / 截屏」一起拖死。
        fbGetIntegerValue      = (FBGetIntValueFn)FBSymIn(handle, "IOHIDEventGetIntegerValue");

        BOOL ok = fbCreateDigitizerEvent && fbCreateFingerEvent && fbAppendEvent && fbSetInt &&
                  fbSetFloat && fbCreateHIDClient && fbDispatchHIDEvent && fbSetSenderID;
        if (!ok) {
            FBLog(@"⚠️ 全局返回：IOKit 里符号取不全（create=%d finger=%d append=%d setint=%d "
                  @"setfloat=%d client=%d dispatch=%d sender=%d）—— 这条路不通，点了会没反应",
                  (int)(fbCreateDigitizerEvent != NULL), (int)(fbCreateFingerEvent != NULL),
                  (int)(fbAppendEvent != NULL), (int)(fbSetInt != NULL),
                  (int)(fbSetFloat != NULL), (int)(fbCreateHIDClient != NULL),
                  (int)(fbDispatchHIDEvent != NULL), (int)(fbSetSenderID != NULL));
            return;
        }

        fbHIDClient = fbCreateHIDClient(kCFAllocatorDefault);
        if (!fbHIDClient) {
            FBLog(@"⚠️ 全局返回：IOHIDEventSystemClientCreate 回了 NULL");
            return;
        }

        loaded = YES;
        FBLog(@"全局返回：HID 注入这条路通了（符号齐、client 建好）");
    });
    return loaded;
}

void FBHIDPrepareChildReaders(void);   // 定义在文件后半段（子事件读取器）

void FBPrepareHID(void)
{
    if (gFBHIDReady) return;
    gFBHIDReady = FBLoadHID();
    if (gFBHIDReady) FBHIDPrepareChildReaders();
    FBLog(@"HID 预热：%@（学 sender ID、注入触摸都要它，必须在 HID 回调之外做）",
          gFBHIDReady ? @"好" : @"失败 —— 注入那条路不可用");
}

int FBHIDEventTypeOf(void *hidEvent)
{
    if (!gFBHIDReady || hidEvent == NULL || !fbGetEventType) return 0;
    return (int)fbGetEventType((IOHIDEventRef)hidEvent);
}

/// 读一个数字字段。⚠️ 函数里**绝不加载**（HID 回调线程上不能 dlopen，见 FBHIDNoteRealEvent）。
static int FBHIDIntField(void *hidEvent, uint32_t field)
{
    if (!gFBHIDReady || hidEvent == NULL || !fbGetIntegerValue) return -1;
    if (!fbGetEventType || fbGetEventType((IOHIDEventRef)hidEvent) != FBHIDEventTypeDigitizer) return -1;
    return fbGetIntegerValue((IOHIDEventRef)hidEvent, field);
}

// 下面三个是**触摸自检**用的（2026-10-17 加）：
// 真机自检显示 AXEventRepresentation 的 isTouchDown 一直是 0（3 万条事件里一次都没「按下」），
// 所以「这一下摸到了没有」不能再只听 AX 的，得直接问底层数字字段。
// 字段含义、以及「按下 = Range+Touch / 抬起 = Touch 变 0」这套约定，
// 来自真机在用的注入工具 ZXTouch（xuan32546/IOS13-SimulateTouch）的 pccontrol/Touch.xm：
// 它造 down 事件时填 Range=1 Touch=1、move 填 Range=1 Touch=1、up 填 Range=0 Touch=0。

/// 手指是否还在屏上：1 = 在屏，0 = 离屏，-1 = 取不到（不是触摸事件 / 符号没准备好）。
int FBHIDDigitizerTouchOf(void *hidEvent)
{
    int v = FBHIDIntField(hidEvent, FBHIDFieldDigitizerTouch);
    return (v < 0) ? -1 : (v & 1);
}

/// 手指是否刚进入感应范围（按下那一下就带这个）：1 / 0 / -1 同上。
int FBHIDDigitizerRangeOf(void *hidEvent)
{
    int v = FBHIDIntField(hidEvent, FBHIDFieldDigitizerRange);
    return (v < 0) ? -1 : (v & 1);
}

/// 原始 EventMask 位（1=Range 2=Touch 4=Position…），-1 = 取不到。只往自检里写。
int FBHIDDigitizerMaskOf(void *hidEvent)
{
    return FBHIDIntField(hidEvent, FBHIDFieldDigitizerEventMask);
}

// ============================================================================
// 0.1.14：**翻子事件**读手指状态
//
// ⚠️ 0.1.11~0.1.13 一直没反应，根子就在这儿：
//    监听到的 `event` 是**父事件（collection）**，Touch / Range / X / Y 这些字段
//    全在它的**子事件（每根手指一个）**上。直接对父事件 GetIntegerValue 读出来
//    永远是 0 —— 于是「有手指=0」→ contactSignal 永不成立 → 一次都不接管。
//    这跟 0.1.8 那组读数（3 万条事件、接管=0）是同一个病的两个版本。
//
// ZXTouch 造触摸时也是「父事件 + 手指子事件」两层（见上面 FBHIDDisplay 那段注释，
// 以及 FBMakeTouchEvent）：坐标在子事件、归一化 0~1。真机事件过来是同一套结构，
// 所以这里顺着 IOHIDEventGetChildren 往下找 type=11 的子事件来读。
// ============================================================================

typedef CFArrayRef (*FBGetChildrenFn)(IOHIDEventRef);
typedef double (*FBGetFloatValueFn)(IOHIDEventRef, uint32_t);

// 归一化坐标字段（与注入时用的 X/Y 同一对，见 IOHIDEvent.h 里 Digitizer 那组）
#define FBHIDFieldDigitizerX   0x0b0000
#define FBHIDFieldDigitizerY   0x0b0001

static FBGetChildrenFn   fbGetChildren   = NULL;
static FBGetFloatValueFn fbGetFloatValue = NULL;

void FBHIDPrepareChildReaders(void)
{
    // 只在启动时调（见 FBPrepareHID 的注释：回调里不许加载）
    if (fbGetChildren) return;
    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    fbGetChildren   = (FBGetChildrenFn)FBSymIn(handle, "IOHIDEventGetChildren");
    fbGetFloatValue = (FBGetFloatValueFn)FBSymIn(handle, "IOHIDEventGetFloatValue");
    FBLog(@"HID：子事件读取器 %@（children=%d float=%d）",
          (fbGetChildren && fbGetFloatValue) ? @"可用" : @"不可用",
          (int)(fbGetChildren != NULL), (int)(fbGetFloatValue != NULL));
}

/// 从「一个事件」上读手指状态。返回：1 = 读到了（*touch/*range 有效），0 = 这个事件上读不到。
static int FBHIDReadOne(void *e, int *touch, int *range, double *nx, double *ny)
{
    if (!e || !fbGetEventType || fbGetEventType((IOHIDEventRef)e) != FBHIDEventTypeDigitizer) return 0;
    int t = FBHIDIntField(e, FBHIDFieldDigitizerTouch);
    int r = FBHIDIntField(e, FBHIDFieldDigitizerRange);
    if (t < 0 && r < 0) return 0;
    if (touch) *touch = (t < 0) ? -1 : (t & 1);
    if (range) *range = (r < 0) ? -1 : (r & 1);
    if (nx || ny) {
        double x = fbGetFloatValue ? fbGetFloatValue((IOHIDEventRef)e, FBHIDFieldDigitizerX) : 0;
        double y = fbGetFloatValue ? fbGetFloatValue((IOHIDEventRef)e, FBHIDFieldDigitizerY) : 0;
        if (nx) *nx = x;
        if (ny) *ny = y;
    }
    return 1;
}

int FBHIDReadTouchDeep(void *hidEvent, int *touch, int *range, double *nx, double *ny)
{
    if (touch) *touch = -1;
    if (range) *range = -1;
    if (nx) *nx = 0;
    if (ny) *ny = 0;
    if (!gFBHIDReady || !hidEvent) return 0;

    // ① 事件自己身上能读到「有手指」就直接用它
    int t = -1, r = -1;
    double x = 0, y = 0;
    if (FBHIDReadOne(hidEvent, &t, &r, &x, &y)) {
        BOOL hasFinger = (t == 1) || (r == 1);
        if (hasFinger || !fbGetChildren) {
            if (touch) *touch = t;
            if (range) *range = r;
            if (nx) *nx = x;
            if (ny) *ny = y;
            return 1;
        }
    }

    // ② 翻子事件：父事件（collection）本身没有手指字段，每根手指是一个 type=11 子事件
    // ⚠️ 0.1.19 修出参契约：下面两条 return 原来返回 `t >= 0 || r >= 0`，
    //    但 ① 那次 **根本没把 t/r/x/y 拷进出参**（454 的条件为假就跳过了 455~458），
    //    于是调用方拿到的是「返回 1（读到了）+ touch=-1 / range=-1」——
    //    而 HUDApp.mm 的契约是「返回 1 就意味着 touch/range 有意义」，
    //    结果这类事件被误记进 `深读(读不到)`，触摸自检读数失真
    //    （0.1.11~0.1.14 排障正是靠这份读数）。
    // 现在两条都先拷出参再返回。
    if (!fbGetChildren) {
        if (touch) *touch = t;
        if (range) *range = r;
        return (t >= 0 || r >= 0) ? 1 : 0;
    }
    CFArrayRef kids = fbGetChildren((IOHIDEventRef)hidEvent);
    if (!kids) {
        if (touch) *touch = t;
        if (range) *range = r;
        return (t >= 0 || r >= 0) ? 1 : 0;
    }

    int bestT = -1, bestR = -1;
    double bestX = 0, bestY = 0;
    BOOL found = NO, foundFinger = NO;
    CFIndex n = CFArrayGetCount(kids);
    for (CFIndex i = 0; i < n; i++) {
        void *kid = (void *)CFArrayGetValueAtIndex(kids, i);
        int kt = -1, kr = -1;
        double kx = 0, ky = 0;
        if (!FBHIDReadOne(kid, &kt, &kr, &kx, &ky)) continue;
        found = YES;
        if (kt == 1 || kr == 1) {          // 优先取「有手指」的那一个
            bestT = kt; bestR = kr; bestX = kx; bestY = ky;
            foundFinger = YES;
            break;
        }
        if (bestT < 0) { bestT = kt; bestR = kr; bestX = kx; bestY = ky; }
    }

    if (touch) *touch = bestT;
    if (range) *range = bestR;
    if (nx) *nx = bestX;
    if (ny) *ny = bestY;
    // ⚠️ 0.1.19：原来写 `found ? 1 : (foundFinger ? 1 : 0)` —— 但 `foundFinger = YES` 时
    //    上面第 477 行早就把 `found` 置成 YES 了，所以后半个分支永远走不到，
    //    整句等价于 `found ? 1 : 0`。写清楚，别让下一个人以为它有别的含义。
    return found ? 1 : 0;
}

void FBHIDNoteRealEvent(void *hidEvent)
{
    // ⚠️ 这里**绝对不能**做 dlopen（不要再调 FBLoadHID）：
    //    本函数是从 HID 回调里调的，那是 backboardd 的事件线程，
    //    在那儿做加载有可能把回调卡住 —— 表现就是「点球直接穿透、球再也不响应」。
    //    预热放在 FBPrepareHID()（HUD 启动时调一次）。
    if (!gFBHIDReady || hidEvent == NULL || gFBRealSenderID != 0) return;
    if (!fbGetEventType || !fbGetSenderID) return;
    if (fbGetEventType((IOHIDEventRef)hidEvent) != FBHIDEventTypeDigitizer) return;

    uint64_t sid = fbGetSenderID((IOHIDEventRef)hidEvent);
    if (sid == 0) return;

    gFBRealSenderID = sid;
    FBLog(@"HID：学到真机 sender ID = 0x%llX（注入触摸要用它，学一次就够）", sid);
}

/// 造一个「父事件 + 一个手指子事件」的两层事件。
/// phase：0 = 按下，1 = 移动，2 = 抬起。坐标是**归一化 0~1**。
/// 返回的事件由调用方 CFRelease；返回 NULL 表示造不出来 —— 调用方必须**整体放弃**。
static IOHIDEventRef FBMakeTouchEvent(int phase, double nx, double ny)
{
    uint64_t ts = mach_absolute_time();

    // 父事件：type=3(hand)、index=99、identity=1，坐标一律 0（坐标在子事件上）
    IOHIDEventRef parent = fbCreateDigitizerEvent(kCFAllocatorDefault, ts, 3, 99, 1,
                                                  0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    if (!parent) return NULL;
    fbSetInt(parent, FBHIDFieldDigitizerDisplayInt, 1);
    fbSetInt(parent, FBHIDFieldEventFlags, 1);

    uint32_t mask;
    Boolean range, touch;
    if (phase == 0)      { mask = FBHIDDigitizerEventRange | FBHIDDigitizerEventTouch; range = 1; touch = 1; }
    else if (phase == 1) { mask = FBHIDDigitizerEventPosition;                        range = 1; touch = 1; }
    else                 { mask = FBHIDDigitizerEventTouch;                           range = 0; touch = 0; }

    IOHIDEventRef finger = fbCreateFingerEvent(kCFAllocatorDefault, ts,
                                               FBHIDInjectFingerIndex, FBHIDInjectFingerIdentity,
                                               mask, nx, ny, 0, 0, 0, range, touch, 0);
    if (!finger) {
        CFRelease(parent);
        return NULL;
    }
    fbSetFloat(finger, FBHIDFieldDigitizerMajorRadius, 0.04);   // 手指粗细（归一化）
    fbSetFloat(finger, FBHIDFieldDigitizerMinorRadius, 0.04);
    fbAppendEvent(parent, finger);
    CFRelease(finger);

    // 父事件上的汇总字段（配方里就是固定填这三个）
    fbSetInt(parent, FBHIDFieldDigitizerEventMask, 0x23);
    fbSetInt(parent, FBHIDFieldDigitizerRange, 1);
    fbSetInt(parent, FBHIDFieldDigitizerTouch, 1);
    return parent;
}

/// 只发一条「抬起」（兜底用）
static void FBSendLoneUp(double nx, double ny)
{
    IOHIDEventRef ev = FBMakeTouchEvent(2, nx, ny);
    if (!ev) return;
    fbSetSenderID(ev, gFBRealSenderID);
    fbDispatchHIDEvent(fbHIDClient, ev);
    CFRelease(ev);
    FBLog(@"全局返回：补发了一条「抬起」（兜底，保证屏幕上不留按着的手指）");
}

/// 挑落点的 y：默认屏幕竖直中点，但**不能落在球自己的矩形上**
/// （落点撞上球的话，我们注入的划动会被球当成「用户在拖它」）。
static double FBPickSwipeY(CGRect ballRect, double screenHeight)
{
    double mid = screenHeight / 2.0;

    // 划动的横向覆盖范围是 0~240pt（见下面那些采样点）
    CGRect band = CGRectMake(0, 0, 245.0, screenHeight);
    if (!CGRectIntersectsRect(ballRect, band)) return mid;
    if (mid < CGRectGetMinY(ballRect) || mid > CGRectGetMaxY(ballRect)) return mid;   // 同一个 y 也不撞

    double lo = 100.0;                    // 上面给状态栏 / 刘海留位置
    double hi = screenHeight - 100.0;     // 下面给 Home Indicator 留位置
    double up = CGRectGetMinY(ballRect) - 60.0;
    double down = CGRectGetMaxY(ballRect) + 60.0;
    if (up >= lo) return up;
    if (down <= hi) return down;
    return mid;                            // 兜底（球不可能把左缘整条都占满）
}

BOOL FBGoBack(CGRect ballRectOnScreen)
{
    // 这里在 HUD 主线程上（球的手势回调 → dispatch 到主队列），做加载是安全的。
    FBPrepareHID();
    if (!gFBHIDReady) {
        FBLog(@"全局返回：HID 注入这条路不通（符号取不到），什么都没做");
        return NO;
    }
    if (gFBRealSenderID == 0) {
        FBLog(@"全局返回：还没学到真机 sender ID（得先摸一下屏幕），这次不注入 —— 不冒险");
        return NO;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now < gFBInjectCooldownUntil) {
        FBLog(@"全局返回：%.2f 秒前刚划过一次，这次忽略（防手抖连点）", gFBInjectCooldownUntil - now);
        return NO;
    }

    // 屏幕尺寸
    CGSize screen = [UIScreen mainScreen].bounds.size;
    double w = MIN(screen.width, screen.height);
    double h = MAX(screen.width, screen.height);
    if (w < 100 || h < 100) {
        FBLog(@"全局返回：屏幕尺寸拿不到（%.0fx%.0f），放弃", w, h);
        return NO;
    }

    // ⚠️ 0.1.19：横屏直接放弃，不猜坐标。
    // 上面 w/h 是按「竖屏短边/长边」取的，而 ballRectOnScreen 是**当前朝向**的矩形：
    // 横屏时 FBPickSwipeY 会拿 h=852 去算 mid=426 —— 那是屏幕外，落点全错。
    // 至于 HID 的归一化坐标到底跟不跟界面旋转，在没有真机读数之前改就是赌：
    // 赌错了会在横屏下往屏幕上乱划一串，比划不中糟糕得多。
    // 先明确放弃 + 留日志，等有真机读数再放开。
    if (screen.width > screen.height) {
        FBLog(@"全局返回：现在是横屏（%.0fx%.0f），归一化坐标系跟旋转的关系还没在真机上验证过，"
              @"这次不注入（竖屏下正常可用）", screen.width, screen.height);
        return NO;
    }

    double y = FBPickSwipeY(ballRectOnScreen, h);

    // 划动的采样点：从**贴左缘** 2pt 划到 235pt。
    // 起点必须贴边 —— 系统判「左缘手势」就是看起点离边多远。
    static const double xs[] = { 2.0, 18.0, 55.0, 110.0, 170.0, 235.0 };
    const int count = (int)(sizeof(xs) / sizeof(xs[0]));

    // ---- ① 空跑预检：只验「造得出来」，造完立刻扔掉 ----
    //
    // ⚠️ 0.1.19 修「全局返回必然不成立」：原来先把 7 个事件**全造完**再逐个派发，
    // 而 FBMakeTouchEvent 的第一行就是 `mach_absolute_time()` —— 于是
    // down / 5×move / up 的 HID 时间戳几乎是同一个瞬间（后面那句「之间 sleep 一点，
    // 时间戳才像是真手划出来的」注释写反了：usleep 只推迟了**派发**，
    // 推不动早已定死的时间戳）。
    // 系统判「左缘返回」靠的就是手指在**时间轴上的位移和速度**，
    // 零时长的 down→move→up 在识别器眼里只是一次点按，功能一定不成立。
    //
    // 保命约束「造不全就一个都不发」必须保留（半串事件会让屏幕上留一根按着
    // 不放的手指），所以拆成两步：先空跑验能力，**真正要发的那串现造现发**。
    for (int i = 0; i <= count; i++) {
        int pi = (i < count) ? i : count - 1;
        int phase = (i == 0) ? 0 : (i == count ? 2 : 1);
        IOHIDEventRef probe = FBMakeTouchEvent(phase, xs[pi] / w, y / h);
        if (!probe) {
            FBLog(@"⚠️ 全局返回：试造第 %d 个事件就造不出来 → 整体放弃（一个都不发，避免卡住触摸）", i);
            return NO;
        }
        CFRelease(probe);
    }

    // ---- ② 现造现发：每条事件的时间戳取自它自己被造出来的那一刻 ----
    gFBInjectCooldownUntil = now + 0.6;
    FBLog(@"全局返回：开始注入（屏幕 %.0fx%.0f，落点 x=2→235 y=%.0f，球矩形=%@）",
          w, h, y, NSStringFromCGRect(ballRectOnScreen));
    for (int i = 0; i <= count; i++) {
        int pi = (i < count) ? i : count - 1;
        int phase = (i == 0) ? 0 : (i == count ? 2 : 1);

        // usleep 放在**造事件之前**：这样这条事件的时间戳才是「此刻」，
        // 和它真正派发出去的时刻对得上（时间戳先定、派发后补的老写法正好相反）。
        if (i > 0) usleep(18 * 1000);      // 18ms ≈ 真实手指划过 235pt 的速度

        IOHIDEventRef ev = FBMakeTouchEvent(phase, xs[pi] / w, y / h);
        if (!ev) {
            FBLog(@"⚠️ 全局返回：第 %d 个事件中途造不出来 —— 剩下的不发了，先补一条抬起", i);
            FBSendLoneUp(xs[count - 1] / w, y / h);
            return NO;
        }
        fbSetSenderID(ev, gFBRealSenderID);
        fbDispatchHIDEvent(fbHIDClient, ev);
        CFRelease(ev);
    }
    FBLog(@"全局返回：注入完了（down + %d 个 move + up）—— 看界面回没回上一页", count - 1);

    // ---- ③ 兜底：500ms 后再补一条「抬起」----
    double nx = xs[count - 1] / w;
    double ny = y / h;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        FBSendLoneUp(nx, ny);
    });
    return YES;
}

#pragma mark - 截屏（两条路，先安全的、再兜底的）
// ============================================================================
// 2026-10-17 用户追加要求。原来这条一直押着（旧结论：要么 dlopen SpringBoard
// 的二进制调它的单例，后果不可控；要么模拟「电源 + 音量加」，网上没有一条
// 「iOS 15.6.1 上确定可用」的配方）。这一版两条都做了，但**顺序和安全等级不同**：
//
// ① `ScreenshotServices` —— 系统自己的截图服务（**优先走这条**）
//    iOS 11 起截图能力从 SpringBoard 搬进了这个私有 framework。SpringBoard 自己的
//    `-takeScreenshotAndEdit:` 和辅助触控的「截屏」都是调它（Apple Wiki 上有反编译）：
//      · `SSScreenCaptureAbilityCheck`        +isAbleToTakeScreenshots（能不能截）
//      · `SSScreenCapturer`                   -takeScreenshotWithPresentationOptions:
//      · `SSScreenCapturerPresentationOptions` -setPresentationMode:(BOOL)  （NO = 只保存）
//    **不注入任何输入** → 没有「卡住一个按键/一根手指」的风险，所以优先走它。
//    ⚠️ 私有类一律 dlopen + NSClassFromString 字符串取（和本文件其它地方一个规矩），
//       取不到就退到 ②；整个过程包在 @try 里：真抛异常也只影响我们自己这个进程
//       （球进程崩了 = 球消失，去 App 把开关关一下再打开就回来了，不动系统）。
//
// ② 注入「音量加 + 电源」组合键 —— iOS 的截图快捷键（兜底）
//    用法号有权威依据（Apple Wiki 的 iPhone 按钮 HID 表：iPhoneOS 的按键就是键盘事件）：
//      · 电源 / 锁屏 = consumer page 0x0C, usage 0x30
//      · 音量加      = consumer page 0x0C, usage 0xE9
//    和【全局返回】同一套注入机制（IOHIDEventSystemClientDispatchEvent + 真机 sender ID），
//    同样遵守那三条保命写法（见本文件顶部）：
//      · 四条事件**先全造出来再发**，造不全就一个都不发；
//      · 用我们自己的「虚拟按键」身份，不碰真手指那一路；
//      · 发完 600ms 再补两条「松开」，保证电源/音量没被一直按着。
//    ⚠️ 电源只按 60ms（远短于长按出「滑动关机」的时间）；就算这一下没被认成
//       组合键，结果也只是**把屏幕锁上**（解锁继续用），不丢东西。
// ============================================================================

#define FBHIDConsumerPage   0x0Cu
#define FBHIDUsageLock      0x30u   // 电源 / 锁屏
#define FBHIDUsageVolumeUp  0xE9u   // 音量加

/// 这次注入之后多久内不再注入（防手抖连点 / 两个手势撞一起）
static NSTimeInterval gFBShotCooldownUntil = 0;

/// 探一下这些私有类在不在（既给日志留念，也给下一版指路）。
static NSString *FBShotClassProbe(void)
{
    NSArray<NSString *> *names = @[ @"SSScreenCapturer",
                                    @"SSScreenCapturerPresentationOptions",
                                    @"SSScreenCaptureAbilityCheck",
                                    @"SSMainScreenSnapshotter",
                                    @"SSOtherScreenSnapshotter",
                                    @"SBScreenShotter",
                                    @"SBScreenFlash" ];
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (NSString *name in names) {
        if (NSClassFromString(name)) [found addObject:name];
    }
    return found.count ? [found componentsJoinedByString:@"、"] : @"（一个都没找到）";
}

/// ① 系统截图服务。YES = 请求已经交出去；NO = 这条路走不通，交给 ②。
/// 返回值：1 = 截成了；0 = 这条路不可用（**可以**降级到按键注入）；
///         2 = **系统策略禁止**（屏幕使用时间之类）—— 这种情况**绝不降级**。
///
/// ⚠️ 0.1.19：原来返回 BOOL，「系统说现在不允许截屏」和「服务不可用」都返回 NO，
///    而 FBTakeScreenshot 是 `if (ViaService()) return 1; if (ViaHID()) return 2;` ——
///    于是「不硬来」那句注释和实际控制流**正好相反**：被策略禁止时反而掉进
///    按键注入那条更危险的兜底。屏幕使用时间这个安全限制形同虚设。
///    现在把「策略禁止」单独用 2 标出来，调用方见到就到此为止。
static int FBScreenshotViaService(void)
{
    static void *handle = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/ScreenshotServices.framework/ScreenshotServices",
                        RTLD_NOW);
        if (!handle) {
            FBLog(@"截屏：打不开 ScreenshotServices（%s）—— 走按键注入那条兜底", dlerror() ?: "?");
        }
    });
    if (!handle) return 0;   // 可降级

    // 能不能截：开了「屏幕使用时间」之类的限制时，系统自己会拒绝
    Class ability = NSClassFromString(@"SSScreenCaptureAbilityCheck");
    if (ability && [ability respondsToSelector:@selector(isAbleToTakeScreenshots)]) {
        BOOL (*ableFn)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
        if (!ableFn(ability, @selector(isAbleToTakeScreenshots))) {
            FBLog(@"截屏：系统说现在不允许截屏（SSScreenCaptureAbilityCheck = NO，"
                  @"常见原因是开了「屏幕使用时间」的限制）—— 不硬来，也不降级到按键注入");
            return 2;   // ← 策略禁止：不是「这条路不好使」，是「这件事被禁止了」
        }
    }

    Class optionsCls = NSClassFromString(@"SSScreenCapturerPresentationOptions");
    Class capturerCls = NSClassFromString(@"SSScreenCapturer");
    if (!optionsCls || !capturerCls) {
        FBLog(@"截屏：ScreenshotServices 里没找到 SSScreenCapturer / …Options（这套系统里实际有：%@）",
              FBShotClassProbe());
        return 0;   // 可降级
    }

    @try {
        id options = [[optionsCls alloc] init];
        SEL setMode = NSSelectorFromString(@"setPresentationMode:");
        if ([options respondsToSelector:setMode]) {
            // NO = 截完直接存相册，不弹编辑界面
            ((void (*)(id, SEL, BOOL))objc_msgSend)(options, setMode, (BOOL)NO);
        }

        id capturer = [[capturerCls alloc] init];
        SEL take = NSSelectorFromString(@"takeScreenshotWithPresentationOptions:");
        if (![capturer respondsToSelector:take]) {
            FBLog(@"截屏：SSScreenCapturer 不认 takeScreenshotWithPresentationOptions: —— 走按键注入");
            return 0;   // 可降级
        }
        ((void (*)(id, SEL, id))objc_msgSend)(capturer, take, options);
    } @catch (NSException *e) {
        FBLog(@"⚠️ 截屏：系统截图服务抛异常（%@）—— 改走按键注入", e.reason);
        return 0;   // 可降级
    }

    FBLog(@"截屏：走系统截图服务（ScreenshotServices）—— 画面会闪一下、图进「相册 → 截屏」");
    return 1;   // 成功
}

/// 造一条「按键」事件（down/up）。返回 NULL = 造不出来 → 调用方必须整体放弃。
static IOHIDEventRef FBMakeKeyEvent(uint32_t usage, BOOL down)
{
    if (!fbCreateKeyboardEvent) return NULL;
    return fbCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(),
                                 FBHIDConsumerPage, usage, down ? (Boolean)1 : (Boolean)0, 0);
}

/// 补发两条「松开」（兜底，保证电源 / 音量没被一直按着）
static void FBSendLoneKeyUp(void)
{
    if (!gFBHIDReady || !fbCreateKeyboardEvent || !fbHIDClient) return;

    IOHIDEventRef evs[2] = { FBMakeKeyEvent(FBHIDUsageLock, NO),
                             FBMakeKeyEvent(FBHIDUsageVolumeUp, NO) };
    for (int i = 0; i < 2; i++) {
        if (!evs[i]) continue;
        fbSetSenderID(evs[i], gFBRealSenderID);
        fbDispatchHIDEvent(fbHIDClient, evs[i]);
        CFRelease(evs[i]);
    }
    FBLog(@"截屏：补发了两条「松开」（兜底，保证电源/音量键没被按着）");
}

/// ② 注入「音量加 + 电源」组合键。YES = 已经发出去。
static BOOL FBScreenshotViaHID(void)
{
    // 这里在 HUD 主线程上（球的手势回调），做加载是安全的。
    FBPrepareHID();
    if (!gFBHIDReady) {
        FBLog(@"截屏：HID 注入这条路不通（符号取不到），什么都没做");
        return NO;
    }
    if (!fbCreateKeyboardEvent) {
        FBLog(@"截屏：这台系统的 IOKit 里没有 IOHIDEventCreateKeyboardEvent —— 按键注入做不了");
        return NO;
    }
    if (gFBRealSenderID == 0) {
        FBLog(@"截屏：还没学到真机 sender ID（得先摸一下屏幕），这次不注入 —— 不冒险");
        return NO;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now < gFBShotCooldownUntil) {
        FBLog(@"截屏：%.2f 秒前刚截过一次，这次忽略（防手抖连点）", gFBShotCooldownUntil - now);
        return NO;
    }

    // ---- ① 四条事件先全造出来（造不全就一个都不发）----
    //      顺序：音量加↓ → 电源↓ → 电源↑ → 音量加↑
    //      中间那 60ms 就是「两个键同时按住」的窗口，系统靠它认组合键。
    IOHIDEventRef volDown  = FBMakeKeyEvent(FBHIDUsageVolumeUp, YES);
    IOHIDEventRef lockDown = FBMakeKeyEvent(FBHIDUsageLock, YES);
    IOHIDEventRef lockUp   = FBMakeKeyEvent(FBHIDUsageLock, NO);
    IOHIDEventRef volUp    = FBMakeKeyEvent(FBHIDUsageVolumeUp, NO);
    if (!volDown || !lockDown || !lockUp || !volUp) {
        FBLog(@"⚠️ 截屏：按键事件造不全 → 一个都不发（避免留下按着不放的键）");
        if (volDown)  CFRelease(volDown);
        if (lockDown) CFRelease(lockDown);
        if (lockUp)   CFRelease(lockUp);
        if (volUp)    CFRelease(volUp);
        return NO;
    }

    // ---- ② 按顺序发 ----
    gFBShotCooldownUntil = now + 2.0;
    IOHIDEventRef seq[4] = { volDown, lockDown, lockUp, volUp };
    const char *labels[4] = { "音量加↓", "电源↓", "电源↑", "音量加↑" };

    FBLog(@"截屏：开始注入按键组合（音量加 + 电源），共 4 条");
    for (int i = 0; i < 4; i++) {
        if (i > 0) usleep(60 * 1000);     // 60ms
        fbSetSenderID(seq[i], gFBRealSenderID);
        fbDispatchHIDEvent(fbHIDClient, seq[i]);
        FBLog(@"截屏：注入 %s", labels[i]);
    }
    for (int i = 0; i < 4; i++) CFRelease(seq[i]);
    FBLog(@"截屏：注入完了 —— 正常的话屏幕会闪一下、图进「相册 → 截屏」");

    // ---- ③ 兜底：600ms 后再补两条「松开」----
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        FBSendLoneKeyUp();
    });
    return YES;
}

int FBTakeScreenshot(void)
{
    int viaService = FBScreenshotViaService();
    if (viaService == 1) return 1;             // 系统截图服务，成功
    if (viaService == 2) return 0;             // 策略禁止（屏幕使用时间）—— 到此为止，不硬来
    if (FBScreenshotViaHID())     return 2;    // 服务不可用，才轮到按键注入兜底
    return 0;
}
