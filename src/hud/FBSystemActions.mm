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
typedef void (*FBAppendEventFn)(IOHIDEventRef, IOHIDEventRef);
typedef void (*FBSetIntFn)(IOHIDEventRef, uint32_t, int);
typedef void (*FBSetFloatFn)(IOHIDEventRef, uint32_t, double);
typedef IOHIDEventSystemClientRef (*FBCreateHIDClientFn)(CFAllocatorRef);
typedef void (*FBDispatchHIDEventFn)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef void (*FBSetSenderIDFn)(IOHIDEventRef, uint64_t);
typedef uint32_t (*FBGetEventTypeFn)(IOHIDEventRef);
typedef uint64_t (*FBGetSenderIDFn)(IOHIDEventRef);

static FBCreateDigitizerEventFn fbCreateDigitizerEvent = NULL;
static FBCreateFingerEventFn    fbCreateFingerEvent    = NULL;
static FBAppendEventFn          fbAppendEvent          = NULL;
static FBSetIntFn               fbSetInt               = NULL;
static FBSetFloatFn             fbSetFloat             = NULL;
static FBCreateHIDClientFn      fbCreateHIDClient      = NULL;
static FBDispatchHIDEventFn     fbDispatchHIDEvent     = NULL;
static FBSetSenderIDFn          fbSetSenderID          = NULL;
static FBGetEventTypeFn         fbGetEventType         = NULL;
static FBGetSenderIDFn          fbGetSenderID          = NULL;

static IOHIDEventSystemClientRef fbHIDClient = NULL;

/// 真机那一路的 sender ID（学到才敢注入；见 FBHIDNoteRealEvent）
static uint64_t gFBRealSenderID = 0;

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
        fbAppendEvent          = (FBAppendEventFn)FBSymIn(handle, "IOHIDEventAppendEvent");
        fbSetInt               = (FBSetIntFn)FBSymIn(handle, "IOHIDEventSetIntegerValue");
        fbSetFloat             = (FBSetFloatFn)FBSymIn(handle, "IOHIDEventSetFloatValue");
        fbCreateHIDClient      = (FBCreateHIDClientFn)FBSymIn(handle, "IOHIDEventSystemClientCreate");
        fbDispatchHIDEvent     = (FBDispatchHIDEventFn)FBSymIn(handle, "IOHIDEventSystemClientDispatchEvent");
        fbSetSenderID          = (FBSetSenderIDFn)FBSymIn(handle, "IOHIDEventSetSenderID");
        fbGetEventType         = (FBGetEventTypeFn)FBSymIn(handle, "IOHIDEventGetType");
        fbGetSenderID          = (FBGetSenderIDFn)FBSymIn(handle, "IOHIDEventGetSenderID");

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

void FBHIDNoteRealEvent(void *hidEvent)
{
    if (hidEvent == NULL || gFBRealSenderID != 0) return;
    if (!FBLoadHID()) return;
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
    if (!FBLoadHID()) {
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

    // 屏幕尺寸：HID 那边按「竖屏的点数」归一化，所以要取 min/max
    CGSize screen = [UIScreen mainScreen].bounds.size;
    double w = MIN(screen.width, screen.height);
    double h = MAX(screen.width, screen.height);
    if (w < 100 || h < 100) {
        FBLog(@"全局返回：屏幕尺寸拿不到（%.0fx%.0f），放弃", w, h);
        return NO;
    }

    double y = FBPickSwipeY(ballRectOnScreen, h);

    // 划动的采样点：从**贴左缘** 2pt 划到 235pt。
    // 起点必须贴边 —— 系统判「左缘手势」就是看起点离边多远。
    static const double xs[] = { 2.0, 18.0, 55.0, 110.0, 170.0, 235.0 };
    const int count = (int)(sizeof(xs) / sizeof(xs[0]));

    // ---- ① 先把整串事件全造出来（造不全就一个都不发，绝不能发一半）----
    IOHIDEventRef evs[16];
    int n = 0;
    for (int i = 0; i < count; i++) {
        IOHIDEventRef ev = FBMakeTouchEvent(i == 0 ? 0 : 1, xs[i] / w, y / h);
        if (!ev) {
            FBLog(@"⚠️ 全局返回：第 %d 个事件造不出来 → 整串放弃（一个都不发，避免卡住触摸）", i);
            for (int k = 0; k < n; k++) CFRelease(evs[k]);
            return NO;
        }
        evs[n++] = ev;
    }
    IOHIDEventRef up = FBMakeTouchEvent(2, xs[count - 1] / w, y / h);
    if (!up) {
        FBLog(@"⚠️ 全局返回：「抬起」造不出来 → 整串放弃（一个都不发，避免卡住触摸）");
        for (int k = 0; k < n; k++) CFRelease(evs[k]);
        return NO;
    }
    evs[n++] = up;

    // ---- ② 按顺序发（之间 sleep 一点，时间戳才像是真手划出来的）----
    gFBInjectCooldownUntil = now + 0.6;
    FBLog(@"全局返回：开始注入（屏幕 %.0fx%.0f，落点 x=2→235 y=%.0f，球矩形=%@）",
          w, h, y, NSStringFromCGRect(ballRectOnScreen));
    for (int i = 0; i < n; i++) {
        if (i > 0) usleep(18 * 1000);      // 18ms
        fbSetSenderID(evs[i], gFBRealSenderID);
        fbDispatchHIDEvent(fbHIDClient, evs[i]);
    }
    for (int i = 0; i < n; i++) CFRelease(evs[i]);
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
