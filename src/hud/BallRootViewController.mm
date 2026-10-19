//
//  BallRootViewController.mm
//
//  悬浮球本体：一个圆 + 四种手势。
//  这个类跑在 root 的 HUD 进程里，窗口是注册给 SpringBoard 的全局窗口。
//
//  ⚠️ 拖动为什么不用 translationInView:
//  窗口本身会跟着手指移动，如果还用 translationInView 算位移，
//  手指在窗口坐标系里的位置会「跟着窗口一起走」，位移会越算越小最后卡死（经典反馈环）。
//  所以这里每个事件都把「窗口内坐标」换算回「屏幕坐标」再定位。
//

#import "BallRootViewController.h"
#import "HUDHelper.h"
#import "FBLog.h"
#import "FBSystemActions.h"

#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <AudioToolbox/AudioToolbox.h>

#import "../helpers/private_headers/LSApplicationWorkspace.h"

// 0.1.22：快捷菜单的那些类定义在文件后半部分，这里先前向声明一下 ——
// 下面 `@interface` 里要用 `NSArray<FBQuietMenuItem *> *` 这种带泛型的写法，
// 那要求编译器在**声明处**就已经知道 FBQuietMenuItem 是什么。
@class FBQuietMenuItem;
@class FBQuietMenuView;

// 0.1.16：这些方法互相调用，先声明一遍，省得编译器报「找不到方法」
@interface BallRootViewController ()
- (BOOL)applyBallStyle;   // 0.1.21：返回「这一轮有没有真的拿到贴图」
- (void)applyLayout;
- (void)refreshLabel;
- (void)writeStyleDiag:(NSString *)source;
// 0.1.22 菜单浮层（互相调用，先声明）
- (void)openQuickMenu;
- (void)closeQuickMenu;
- (void)toggleQuickMenu;
- (void)updatePassThroughRegion;
- (NSArray<FBQuietMenuItem *> *)loadMenuItems;
- (NSString *)symbolForActionId:(NSString *)actionId;
- (void)quickMenuDidSelectIndex:(NSInteger)idx;
@end

// 默认值
static const CGFloat kDefaultBallSize = 56.0;
static const CGFloat kWindowPadding = 12.0;   // 窗口比球大一圈：给阴影和手指宽容区
static NSString *const kDefaultBallStyle = @"BallDot";   // 贴图名（见 scripts/make_icon.py）

// ---- 震动反馈 ----
//
// 开关 + 两个参数都存在共享设置里（App「启动」页：「震动反馈」开关、强度滑块、时长滑块）。
// App 那边有一份等价实现（src/controllers/Haptics.swift）——
// ⚠️ 键名 / 默认值 / 分段算法 两边必须一模一样，改一边就得改另一边。
//
// ⚠️ 手机的**静音键**不影响这里（系统振动照走）；「设置 → 声音与触感 → 系统触感反馈」
//    关掉只影响 Taptic 引擎那种细腻反馈，不影响 `kSystemSoundID_Vibrate` 的整机振动。
typedef NS_ENUM(NSInteger, FBHapticKind) {
    FBHapticTap = 0,   // 识别到点击 / 球落位                —— 轻
    FBHapticAction,    // 动作真的执行了（移动模式、数字开关）—— 中
    FBHapticNotice,    // 「交代出去一件事」（刷新信号）      —— 两下
};

// 震动参数（键名与 Haptics.swift 共用）：
//   强度 `HapticIntensity`  0.2~1.0（默认 1.0）→ 直接交给系统声音的 Intensity
//   ~~时长 `HapticDurationMs`~~ —— **0.1.12 起作废**：用户实测「连敲拼时长」效果一般，
//        于是直接去掉，一律就系统默认那一下（≈40ms；Taptic 引擎敲一下的长度是系统定死的，
//        想精确到毫秒得用 CoreHaptics，而它要求 App 在前台 + 有音频会话，HUD 里不靠谱）。
//        ⚠️ 只有 `FBHapticNotice`（「交代出去一件事」）保留**两下** —— 那是信号，不是时长。
//        ⚠️ 老版本写进设置的 `HapticDurationMs` 现在**没人读**了（不用清，不影响）。
#define FBHapticPulseSpacingMs  40    // 两下之间隔多少毫秒（只给 notice 的两下用）

/// 球控制器（viewDidLoad 时登记），给 FBBallHapticTouchDown() 用的。
static BallRootViewController *sBallVC = nil;

// ⭐ 0.1.31：震动换路 —— 从 UIImpactFeedbackGenerator 改成 AudioToolbox 的系统声音振动。
//
// 为什么换（用户 0.1.30 反馈「震动强度设定和它这个并没有起作用」）：
//   HUD 是 `posix_spawn` 出来的**后台进程**（persona 99 / uid 0），不是前台 App。
//   `UIImpactFeedbackGenerator` 的 Taptic 反馈只在前台有效 —— 后台进程调它，系统
//   **直接吞掉**（0.1.16 自喂测试：手势成功、计数 +1，但一点震感都没有，就是这条）。
//   既然压根没震，强度滑块当然「没起作用」。
//
//   `AudioServicesPlaySystemSoundWithVibration` 是 AudioToolbox 里的私有函数，
//   走**系统声音服务**：不需要前台、不需要音频会话，root 守护进程也能震
//   （越狱环境里的 `vibrate` 命令行就是同一个调用）。它的 `Intensity` 参数
//   正好能吃设置里的 0.2~1.0 —— 强度滑块从这一版起才真的有作用。
//
//   用 dlsym 取符号而不是直接声明：这个函数不在公开头文件里。拿不到符号时退回
//   `AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)`（固定强度，至少能震）。
typedef void (*FBVibrateWithPatternFn)(UInt32, id, NSDictionary *);

static FBVibrateWithPatternFn sVibrateWithPattern = NULL;
static BOOL sVibrateSymbolLoaded = NO;

static void FBLoadVibrateSymbol(void)
{
    if (sVibrateSymbolLoaded) return;
    sVibrateSymbolLoaded = YES;

    void *h = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_LAZY);
    if (h) {
        sVibrateWithPattern = (FBVibrateWithPatternFn)dlsym(h, "AudioServicesPlaySystemSoundWithVibration");
    }
    FBLog(@"震动：系统声音通路%@（%@）",
          sVibrateWithPattern ? @"可用" : @"不可用，退回固定强度",
          sVibrateWithPattern ? @"AudioServicesPlaySystemSoundWithVibration"
                              : @"AudioServicesPlaySystemSound");
}

/// 敲一下（强度来自设置）
static void FBHapticPulse(FBHapticKind kind, CGFloat intensity)
{
    (void)kind;   // 系统声音振动只有一种音色，轻 / 中不再区分（敲几下仍由 FBHapticPlay 决定）

    FBLoadVibrateSymbol();

    double v = (double)MAX(0.05, MIN(intensity, 1.0));
    if (sVibrateWithPattern) {
        // VibePattern 是「开/关 + 毫秒」交替的数组：这里震 40ms（系统默认那一下）
        NSDictionary *pattern = @{ @"VibePattern": @[ @YES, @(FBHapticPulseSpacingMs) ],
                                   @"Intensity":   @(v) };
        sVibrateWithPattern((UInt32)kSystemSoundID_Vibrate, nil, pattern);
        return;
    }

    // 兜底：固定强度，至少能感觉到「按到了」
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

/// - Parameters:
///   - kind:      震感种类（决定敲几下；0.1.31 起系统声音只有一种音色）
///   - intensity: 0.2~1.0（设置里的「强度」）
///   ⚠️ 0.1.12 起没有「敲几下」这个入参了：时长不再可调，一律一下
///      （只有 `FBHapticNotice` 例外，见下）。
static void FBHapticPlay(FBHapticKind kind, CGFloat intensity)
{
    // ⚠️ 一律「系统默认那一下」（≈40ms）；只有 FBHapticNotice（「交代出去一件事」）
    //    敲两下 —— 那是一个**信号**，不是时长设置。
    int n = (kind == FBHapticNotice) ? 2 : 1;

    for (int i = 0; i < n; i++) {
        if (i == 0) {
            FBHapticPulse(kind, intensity);
            continue;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)((int64_t)i * FBHapticPulseSpacingMs * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{ FBHapticPulse(kind, intensity); });
    }

}

/// 只有球本身吃触摸，窗口里那圈余量（阴影/宽容区）的触摸对象返回 NO，
/// 让它有机会「漏」给下面的 App。
///
/// ⚠️ 这是个**安全阀**，不是装饰：万一 SpringBoard 把这个远程窗口当成整屏的，
///    吞掉的就是整块屏幕（手机会变得点不动）。有这一层，至少还有机会漏下去。
///    真出事了还有最后的兜底：**重启手机**（悬浮球不是守护进程，不开机自启。
@interface FBPassThroughView : UIView
@property (nonatomic, weak) UIView *interactiveSubview;
@end

@implementation FBPassThroughView

/// 球外面 10pt 的宽容区：手指是有宽度的（指尖接触面 40~50px），
/// 球才 56pt，按得偏一点就漏给下面的 App 了 —— 「怎么点都点不中」多半是这个。
static const CGFloat kBallTouchSlack = 10.0;

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    // ⚠️ 0.1.19：原来这里 `return [super pointInside:...]` —— 球还没建好的那一瞬间
    //    （viewDidLoad 还没跑到 setInteractiveSubview:）整屏触摸都会被这个全屏根视图吃掉。
    //    「没有球」= 「这里不该吃任何触摸」，必须返回 NO。
    if (!self.interactiveSubview) return NO;

    // ⚠️ 0.1.19：改用 convertRect:fromView: 换算，而不是直接拿 `interactiveSubview.frame`。
    //    `frame` 是**父视图**（本视图）坐标系里的值，`pointInside:` 收到的 `point` 也是
    //    本视图坐标系 —— 只有两者原点一致时才碰巧对得上。
    //    根视图的 bounds.origin 一旦非 0（旋转 / 安全区 / UIKit 挪过），
    //    整块命中区域就会偏移，表现正是「球在那儿，点不到」。
    //    convertRect: 还顺带把 pressFeedback 那个 0.86 缩放算进去。
    CGRect touchable = [self convertRect:self.interactiveSubview.bounds
                                 fromView:self.interactiveSubview];
    touchable = CGRectInset(touchable, -kBallTouchSlack, -kBallTouchSlack);
    BOOL inside = CGRectContainsPoint(touchable, point);
    // 自检：系统问我们「这个点是不是你的」时记一笔（0.1.8 加的）。
    // ⚠️ 0.1.19：`_ignoresHitTest` 改回 YES 之后，这一行在真机上**长期是 0** ——
    //    这正是我们要的：说明系统没在拿我们这个全屏窗口做命中测试。
    FBProbeTouchHit(inside);
    return inside;
}

@end

/// 菜单里的一项。点它就把 key 交给 BallRootViewController 去执行。

static const CGFloat kMenuRowH     = 40.0;   // 一行多高
static const CGFloat kMenuRowGap   = 4.0;    // 行间距
static const CGFloat kMenuPadX     = 14.0;   // 左右内边距
static const CGFloat kMenuPadY     = 8.0;
static const CGFloat kMenuCorner   = 14.0;
static const CGFloat kMenuWidth    = 168.0;
static const CGFloat kMenuGapFromBall = 10.0;
static const CGFloat kMenuMaxRows  = 8.0;    // 超过就滚动不了，所以条数上限就是 8

@interface FBQuietMenuItem : NSObject
@property (nonatomic, copy) NSString *key;      // "app:xxx" / "action:xxx" / "url:xxx"
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *symbol;   // SF Symbol 名
@end
@implementation FBQuietMenuItem
@end

@interface FBQuietMenuView : UIView
@property (nonatomic, weak) id menuTapHandler;   // BallRootViewController
- (instancetype)initWithItems:(NSArray<FBQuietMenuItem *> *)items;
@end

@implementation FBQuietMenuView {
    NSInteger _itemCount;
    NSInteger _pressedIndex;     // 按下时落在第几行（-1 = 没落在行上）
    NSTimeInterval _beganAt;
}

- (instancetype)initWithItems:(NSArray<FBQuietMenuItem *> *)items
{
    CGFloat h = kMenuPadY * 2 + items.count * kMenuRowH + MAX(0, (CGFloat)items.count - 1) * kMenuRowGap;
    if (self = [super initWithFrame:CGRectMake(0, 0, kMenuWidth, h)]) {
        _itemCount = (NSInteger)items.count;
        _pressedIndex = -1;
        self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
        self.layer.cornerRadius = kMenuCorner;
        self.layer.masksToBounds = YES;
        // 菜单要投一层影在下面的 App 上，不然糊成一片看不清
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.45;
        self.layer.shadowRadius = 12.0;
        self.layer.shadowOffset = CGSizeMake(0.0, 4.0);
        self.userInteractionEnabled = YES;

        // 出现动画：从球那一侧缩出来。用 alpha+scale，纯 transform 不依赖任何系统服务。
        self.alpha = 0.0;
        self.transform = CGAffineTransformMakeScale(0.86, 0.86);
        [UIView animateWithDuration:0.16 animations:^{
            self.alpha = 1.0;
            self.transform = CGAffineTransformIdentity;
        }];

        CGFloat y = kMenuPadY;
        for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
            FBQuietMenuItem *item = items[i];

            // ⚠️ 0.1.29：行改成**不参与交互**的普通 UIView。
            //    原因：合成触摸的「抬起」坐标经常丢（本机 [rep location] 恒 (0,0)），
            //    而 UIControl 的 touchUpInside 要求「抬起时手指还在这一行」——
            //    坐标一丢就被判成「在外面松手」，动作永远不触发（用户实测：菜单点不动）。
            //    现在整块菜单由容器自己收触摸（touchesBegan/Ended），按坐标算行号；
            //    行不参与 hitTest，命中测试也只会落在容器上。
            UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, y, kMenuWidth, kMenuRowH)];
            row.userInteractionEnabled = NO;
            row.backgroundColor = [UIColor clearColor];
            [self addSubview:row];

            UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:item.symbol]];
            icon.tintColor = [UIColor whiteColor];
            icon.contentMode = UIViewContentModeScaleAspectFit;
            icon.frame = CGRectMake(kMenuPadX, (kMenuRowH - 18) / 2, 18, 18);
            icon.userInteractionEnabled = NO;
            [row addSubview:icon];

            UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(kMenuPadX + 26, 0,
                                                                         kMenuWidth - kMenuPadX - 26 - 8,
                                                                         kMenuRowH)];
            label.text = item.title;
            label.textColor = [UIColor whiteColor];
            label.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
            label.userInteractionEnabled = NO;
            [row addSubview:label];

            y += kMenuRowH + kMenuRowGap;
        }
    }
    return self;
}

/// 本视图坐标 → 行号；不在任何一行上返回 -1
- (NSInteger)indexAtPoint:(CGPoint)p
{
    if (p.x < 0.0 || p.x > CGRectGetWidth(self.bounds)) return -1;
    CGFloat y = p.y - kMenuPadY;
    if (y < 0.0) return -1;
    CGFloat step = kMenuRowH + kMenuRowGap;
    NSInteger i = (NSInteger)(y / step);   // y >= 0，截断即 floor
    CGFloat within = y - (CGFloat)i * step;
    if (within > kMenuRowH) return -1;          // 落在行间距里
    if (i < 0 || i >= _itemCount) return -1;
    return i;
}

- (void)setPressedIndex:(NSInteger)idx
{
    if (idx == _pressedIndex) return;
    if (_pressedIndex >= 0 && _pressedIndex < (NSInteger)self.subviews.count) {
        self.subviews[_pressedIndex].backgroundColor = [UIColor clearColor];
    }
    _pressedIndex = idx;
    if (idx >= 0 && idx < (NSInteger)self.subviews.count) {
        self.subviews[idx].backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    UITouch *t = touches.anyObject;
    _beganAt = t.timestamp;
    CGPoint p = [t locationInView:self];
    NSInteger idx = [self indexAtPoint:p];
    FBLog(@"菜单触摸：按下 (%.1f,%.1f) → 第 %ld 行", p.x, p.y, (long)idx);
    [self setPressedIndex:idx];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    UITouch *t = touches.anyObject;
    [self setPressedIndex:[self indexAtPoint:[t locationInView:self]]];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    UITouch *t = touches.anyObject;
    CGPoint end = [t locationInView:self];
    NSInteger up = [self indexAtPoint:end];
    NSInteger down = _pressedIndex;

    // 抬起坐标丢了（(0,0) 或跑到菜单外很远）→ 按「按下时那一行」算。
    // 菜单行 40pt 高，正常点击不会拖出很远；只有坐标坏掉才会跳那么远。
    BOOL bogusEnd = (end.x == 0.0 && end.y == 0.0)
                 || !CGRectContainsPoint(CGRectInset(self.bounds, -80.0, -80.0), end);
    if (up < 0 && bogusEnd && down >= 0 && (t.timestamp - _beganAt) < 0.8) {
        up = down;
    }

    [self setPressedIndex:-1];
    FBLog(@"菜单触摸：抬起 (%.1f,%.1f) down=%ld up=%ld %@",
          end.x, end.y, (long)down, (long)up,
          (up >= 0 && up == down) ? @"→ 执行" : @"→ 取消");
    if (up < 0 || up != down) return;   // 没按在行上 / 按下抬起不是同一行 = 取消

    BallRootViewController *vc = (BallRootViewController *)self.menuTapHandler;
    // 走的是 UIResponder 的触摸派发，和手势一样由 UIKit 送来；
    // 合成触摸喂进来时照样会被调到（所以这里不再用 UIControl 的 target-action）。
    if ([vc respondsToSelector:@selector(quickMenuDidSelectIndex:)]) {
        [vc quickMenuDidSelectIndex:up];
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self setPressedIndex:-1];
}

@end
@implementation BallRootViewController {
    UIImageView *_ball;       // 球本体（贴图；样式可在 App 里换）
    UILabel *_label;
    NSMutableDictionary *_prefs;
    CGPoint _grabOffset;      // 手指按下时，落在窗口内的位置
    BOOL _showText;           // 是否显示球上的数字（存在 ShowLabel 键里）
    BOOL _fallbackBall;       // 贴图丢了、退化成纯色球时，要给它留一圈描边
    BOOL _moveMode;           // 「移动模式」：球高亮，拖一下就落位，点一下退出
    // 0.1.22：快捷菜单浮层
    FBQuietMenuView *_menuView;
    NSArray<FBQuietMenuItem *> *_menuItems;
    UIView *_passThroughRegion;   // 球 ∪ 菜单 的包围矩形（只给 pointInside: 用，不参与绘制）
}

#pragma mark - 震动

/// 0.1.31：从磁盘重读「开关 + 强度」。
/// 为什么：HUD 是 root 守护进程，App 发来的 Darwin 通知**不一定送得到**
/// （0.1.11 起连开关状态都改成读 pid 文件了，原因一样）。原来只在启动/收到通知时读，
/// 用户在 App 里拖强度滑块 → 球这边还是旧值 → 就是「强度设定没起作用」。
/// 这份 plist 很小，读一次是微秒级，放在每次震动前完全值得。
- (void)reloadHapticPrefs
{
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:USER_DEFAULTS_PATH];
    if (!onDisk) return;
    for (NSString *k in @[@"HapticsEnabled", @"HapticIntensity"]) {
        id v = onDisk[k];
        if (v) _prefs[k] = v;
        else [_prefs removeObjectForKey:k];   // 没设过 = 默认（开关开、强度 1.0）
    }
}

/// 设置里的「强度」（0.2~1.0，默认 1.0）。算法与 Haptics.swift 的 Haptics.intensity 一致。
- (CGFloat)hapticIntensity
{
    NSNumber *n = _prefs[@"HapticIntensity"];
    double v = n ? [n doubleValue] : 1.0;
    return (CGFloat)MAX(0.2, MIN(v, 1.0));
}

/// 走开关的震动：设置里 `HapticsEnabled` 是 false 就什么都不做。
/// ⚠️ 用「没设过 = 开」的语义：老版本升上来时这个键不存在，不该变成静音。
/// ⚠️ 0.1.12 起不再有「敲几下」——时长不可调（见文件顶部）。
- (void)haptic:(FBHapticKind)kind
{
    [self reloadHapticPrefs];

    NSNumber *on = _prefs[@"HapticsEnabled"];
    if ([on isKindOfClass:[NSNumber class]] && ![on boolValue]) return;

    FBHapticPlay(kind, [self hapticIntensity]);
}

/// HUD 那边「起手在球上」那一刻调（0.1.12：「按下去就震」，用户 2026-10-17 定的）。
///
/// 以前的震动全靠球上的手势判出来才给（单击 / 长按 / 落位），
/// 而手势认不认得出来一直是这条链上最脆的一环 —— 手势一失灵，按球就一点反馈都没有。
/// 现在把「震一下」提到**最早、最不依赖别人的那一刻**：手落到球上就震，
/// 后面的手势要不要再震一层（长按、动作执行）照旧 —— 那是「确认」，这里是「迎客」。
void FBBallHapticTouchDown(void)
{
    // 0.1.16：再加一层**看得见**的反馈：球按下去缩一下 —— 这一层不依赖任何系统服务。
    // 0.1.31：震动本身改走系统声音（见文件顶部），所以现在「缩一下」和「震一下」
    //         都会真的发生；缩球仍然保留：系统「触感反馈」总开关被关掉时它是唯一反馈。
    [sBallVC haptic:FBHapticTap];
    [sBallVC pressFeedback];
}

/// 2 秒一次的巡检：外观文件有没有变（0.1.16 用户反馈：改形状/颜色/大小/透明度都没反应）。
/// 通知有可能没送到（或送到时刚写了一半），所以每 2 秒比对一次文件修改时间 ——
/// plist 或贴图变了就重新应用，**不依赖通知**。
/// ⚠️ 0.1.31 起这个定时器**不再管震动保温**（震动换成系统声音，不需要预热引擎）。
- (void)pollTimerTick
{
    [self pollAppearanceFiles];
}

- (void)pollAppearanceFiles
{
    // ⚠️ 0.1.19 修「点一下球，球就闪一下」：
    //    原来拿**整份 plist 的 mtime**当判据。可 HUD 每点一下球（TapCount）、
    //    每拖一次（BallX/BallY）都要 savePrefs → plist mtime 必变 →
    //    两秒内必走一次 loadPrefs + applyBallStyle + applyLayout。
    //    applyBallStyle 会重新读图并重设 _ball.image → 球当众闪一下；
    //    applyLayout 还会重设 frame → 手指还按在球上时球会跳。
    //    这跟「改了外观没反应」是两码事，但都会让人觉得球在抽风。
    //
    // 现在只看**真正决定外观的那几项**（键值 + 贴图文件的 mtime/大小）。
    static NSString *sLastLook = nil;

    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:USER_DEFAULTS_PATH];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *imgAttrs = [fm attributesOfItemAtPath:BALL_IMAGE_PATH error:NULL];

    NSMutableString *look = [NSMutableString string];
    for (NSString *k in @[@"BallShape", @"BallColor", @"BallSize",
                          @"BallOpacity", @"ShowLabel", @"CustomImage"]) {
        [look appendFormat:@"%@=%@;", k, onDisk[k] ?: @"-"];
    }
    [look appendFormat:@"img=%.0f/%llu;",
     [imgAttrs[NSFileModificationDate] timeIntervalSince1970],
     (unsigned long long)[imgAttrs[NSFileSize] unsignedLongLongValue]];

    if (!sLastLook) { sLastLook = look; return; }   // 第一次只记基准
    if ([look isEqualToString:sLastLook]) return;

    FBLog(@"外观变了（%@），重新应用", look);

    [self loadPrefs];
    BOOL ok = [self applyBallStyle];
    [self applyLayout];
    [self refreshLabel];

    // ⚠️ 0.1.21：**别在失败时也把基准记死**。
    // 贴图正被另一个进程改写时，这一轮很可能读到半截的 PNG → 退回默认图。
    // 以前不管成不成都把 sLastLook 更新了，于是「这一轮没读到」= 永久不再重试
    // → 点「重新应用外观」球纹丝不动。改成：只有真的拿到了图才记基准，
    // 下个 2 秒周期还会再试一次。
    if (ok || _fallbackBall == NO) {
        sLastLook = look;
    } else {
        FBLog(@"⚠️ 这一轮没读到完整贴图，先不记基准，2 秒后再试");
    }
}

/// 把「现在到底用了哪张图、球多大、透明度多少」写到 /tmp/FloatingBall.style，
/// App 的「关于」页读出来显示（0.1.16 外观诊断）。
- (void)writeStyleDiag:(NSString *)source
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *cfgAttrs = [fm attributesOfItemAtPath:USER_DEFAULTS_PATH error:NULL];
    NSDictionary *imgAttrs = [fm attributesOfItemAtPath:BALL_IMAGE_PATH error:NULL];
    NSTimeInterval cfg = [cfgAttrs[NSFileModificationDate] timeIntervalSince1970];
    NSTimeInterval img = [imgAttrs[NSFileModificationDate] timeIntervalSince1970];

    NSString *text = [NSString stringWithFormat:
        @"图=%@\n"
        @"形状=%@\n"
        @"颜色=%@\n"
        @"球直径=%.1f\n"
        @"窗口边长=%.1f\n"
        @"球_alpha=%.2f\n"
        @"球=%.0f,%.0f,%.0f,%.0f\n"
        @"plist时间=%.0f\n"
        @"贴图时间=%.0f\n"
        @"贴图字节=%llu\n",
        source,
        _prefs[@"BallShape"] ?: @"(没设)",
        _prefs[@"BallColor"] ?: @"(没设)",
        [self ballSize], [self windowSide], _ball.alpha,
        _ball.frame.origin.x, _ball.frame.origin.y,
        _ball.frame.size.width, _ball.frame.size.height,
        cfg, img,
        (unsigned long long)[imgAttrs[NSFileSize] unsignedLongLongValue]];
    [text writeToFile:@"/tmp/FloatingBall.style"
           atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

/// 按下去的**可见**反馈：球缩一下再弹回。
/// ⚠️ 0.1.16 加这个是因为真机确认：HUD 是后台进程，UIImpactFeedbackGenerator 的震动
///    会被系统吞掉（自喂测试手势成功、计数+1，但一点震感都没有）。
///    缩放只是改 transform，不依赖任何系统服务，一定能看见。
/// ⚠️ 0.1.31 震动换成了系统声音（能震了），但这一层**继续保留**：
///    系统「触感反馈」被关掉、或用户在设置里关掉震动开关时，它是唯一的按下去反馈。
- (void)pressFeedback
{
    if (!_ball) return;
    [UIView animateWithDuration:0.07 delay:0.0
                         options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                      animations:^{
        self->_ball.transform = CGAffineTransformMakeScale(0.86, 0.86);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.12 delay:0.0
                             options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                          animations:^{
            self->_ball.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];
}

#pragma mark - 设置（和 App 共享 /var/mobile/Library/Preferences 下同一个 plist）

- (void)loadPrefs
{
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:USER_DEFAULTS_PATH];
    _prefs = onDisk ? [onDisk mutableCopy] : [NSMutableDictionary dictionary];
    if (!_prefs[@"BallSize"])  _prefs[@"BallSize"]  = @(kDefaultBallSize);
    if (!_prefs[@"TapCount"])  _prefs[@"TapCount"]  = @0;

    // 0.1.15：「关于」页的盲喂开关（验证用，默认关）
    NSNumber *blind = _prefs[@"BlindFeed"];
    gFBBlindFeed = [blind isKindOfClass:[NSNumber class]] && [blind boolValue];
}

- (void)savePrefs
{
    // ⚠️⚠️ 0.1.17 修（用户 0.1.16 反馈「改形状/颜色/大小/透明度都没反应」）：
    //   以前这里是 `[_prefs copy] writeToFile:` —— 把 HUD **启动时读进来的旧快照整份写回**。
    //   App 改了外观 → HUD 只要点一下球/拖一下（都会 savePrefs），就把旧值盖回去，
    //   于是外观永远是旧的（诊断里「直径 52 / 透明度 0.95」就是被盖回去的旧值）。
    //   现在：**只回写 HUD 自己负责的键**，其余键以磁盘上的为准；写完全内存也跟磁盘对齐。
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:USER_DEFAULTS_PATH];
    NSMutableDictionary *disk = onDisk ? [onDisk mutableCopy] : [NSMutableDictionary dictionary];

    static NSArray<NSString *> *ownedKeys = nil;
    if (!ownedKeys) {
        ownedKeys = @[@"TapCount", @"BallX", @"BallY", @"ShowLabel", @"PendingTab"];
    }
    for (NSString *k in ownedKeys) {
        id v = _prefs[k];
        if (v) disk[k] = v;
        else [disk removeObjectForKey:k];
    }

    if ([disk writeToFile:USER_DEFAULTS_PATH atomically:YES]) {
        _prefs = disk;      // 外观那些键也顺手更新成磁盘上的最新值
    }
}

- (CGFloat)ballSize
{
    NSNumber *n = _prefs[@"BallSize"];
    CGFloat size = n ? [n doubleValue] : kDefaultBallSize;
    return MAX(24.0, MIN(size, 160.0));
}

- (CGFloat)windowSide
{
    // ⚠️ 0.1.18：窗口已经是**全屏**的了（照抄 TheBall），这个值不再代表窗口，
    //    只留着给「宽度相关的余量/诊断」用。
    return [self ballSize] + kWindowPadding * 2.0;
}

- (CGRect)screenBounds
{
    return [UIScreen mainScreen].bounds;
}

- (CGPoint)defaultCenter
{
    CGRect sb = [self screenBounds];
    return CGPointMake(CGRectGetMaxX(sb) - 44.0, CGRectGetMidY(sb));
}

- (CGPoint)clampedCenter:(CGPoint)c
{
    CGRect sb = [self screenBounds];
    // 0.1.18：球在**全屏窗口内**移动，边界按球半径算（以前是按「小窗口」算的）
    CGFloat half = [self ballSize] / 2.0;
    CGFloat x = MAX(half, MIN(c.x, CGRectGetMaxX(sb) - half));
    CGFloat y = MAX(half, MIN(c.y, CGRectGetMaxY(sb) - half));
    return CGPointMake(x, y);
}

- (CGPoint)initialCenter
{
    [self loadPrefs];
    NSNumber *x = _prefs[@"BallX"];
    NSNumber *y = _prefs[@"BallY"];
    CGPoint c = (x && y && [x doubleValue] >= 0 && [y doubleValue] >= 0)
        ? CGPointMake([x doubleValue], [y doubleValue])
        : [self defaultCenter];
    return [self clampedCenter:c];
}

#pragma mark - 生命周期

- (void)loadView
{
    // 用自定义的根视图：只有球那块区域吃触摸（见 FBPassThroughView）
    FBPassThroughView *root = [[FBPassThroughView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    root.backgroundColor = [UIColor clearColor];
    self.view = root;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    sBallVC = self;   // 登记给 FBBallHapticTouchDown()（HUD「起手在球上」那一震走这里）
    [self loadPrefs];

    // 震动（0.1.31）：改成 AudioToolbox 的系统声音振动（见文件顶部），
    // 不再需要常驻生成器 / 预热；这个定时器只剩 2 秒一次的外观巡检。
    // 顺手把符号先加载一次，第一下震动不用等 dlopen。
    FBLoadVibrateSymbol();
    [NSTimer scheduledTimerWithTimeInterval:2.0
                                     target:self
                                   selector:@selector(pollTimerTick)
                                   userInfo:nil
                                    repeats:YES];

    // 数字显示不显示，存在共享设置里（App 那边的「显示/隐藏数字」动作也改这个键）
    NSNumber *showLabel = _prefs[@"ShowLabel"];
    _showText = showLabel ? [showLabel boolValue] : YES;

    self.view.backgroundColor = [UIColor clearColor];

    CGFloat ball = [self ballSize];

    // 球本体用贴图（样式可以在 App 里换），贴图由 scripts/make_icon.py 生成。
    // ⚠️ 0.1.18：根视图是**全屏**的，所以球的 frame 直接用**屏幕坐标**（球心 ± 半径）。
    CGPoint startCenter = [self initialCenter];
    _ball = [[UIImageView alloc] initWithFrame:CGRectMake(startCenter.x - ball / 2.0,
                                                          startCenter.y - ball / 2.0,
                                                          ball, ball)];
    _ball.contentMode = UIViewContentModeScaleAspectFit;
    _ball.userInteractionEnabled = YES;
    // 阴影得自己画：贴图是透明底的，没有背景色可以借
    _ball.layer.shadowColor = [UIColor blackColor].CGColor;
    _ball.layer.shadowOpacity = 0.35;
    _ball.layer.shadowRadius = 6.0;
    _ball.layer.shadowOffset = CGSizeMake(0.0, 2.0);
    [self.view addSubview:_ball];
    [self applyBallStyle];

    if ([self.view isKindOfClass:[FBPassThroughView class]]) {
        [(FBPassThroughView *)self.view setInteractiveSubview:_ball];
    }

    // 把球交给 HUD 的触摸回调（全局 HID 事件那条路要用它算「按在球上」）
    FBHUDSetBallView(_ball);

    _label = [[UILabel alloc] initWithFrame:_ball.bounds];
    _label.textAlignment = NSTextAlignmentCenter;
    _label.textColor = [UIColor whiteColor];
    _label.font = [UIFont systemFontOfSize:MAX(11.0, ball * 0.32) weight:UIFontWeightSemibold];
    // 给数字加个淡淡的描边阴影：换成「白点」样式时白字压白底会看不见
    _label.layer.shadowColor = [UIColor blackColor].CGColor;
    _label.layer.shadowOpacity = 0.55;
    _label.layer.shadowRadius = 2.0;
    _label.layer.shadowOffset = CGSizeMake(0.0, 1.0);
    [_ball addSubview:_label];
    [self refreshLabel];

    // ---- 手势：点击 / 双击 / 滑动（拖动） / 长按 ----
    UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onSingleTap:)];
    singleTap.numberOfTapsRequired = 1;

    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;

    // 单击必须等双击判定失败，否则双击会被当成两次单击
    [singleTap requireGestureRecognizerToFail:doubleTap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    longPress.minimumPressDuration = 0.5;

    for (UIGestureRecognizer *g in @[singleTap, doubleTap, pan, longPress]) {
        [_ball addGestureRecognizer:g];
    }

    // 设置被改了 -> 重读
    int token;
    notify_register_dispatch(NOTIFY_RELOAD_HUD, &token, dispatch_get_main_queue(), ^(int t) {
        FBLog(@"收到「设置变了」通知，重读");
        [self reloadSettings];
    });

    // 0.1.14：「关于」页的「自喂测试」按钮 —— 绕过 HID 检测层，直接往球心喂一次点击。
    int tapToken;
    notify_register_dispatch(NOTIFY_SELFTEST_TAP, &tapToken, dispatch_get_main_queue(), ^(int t) {
        FBLog(@"[自喂测试] 收到 App 那边的请求");
        FBSelfTestFeedTap();
    });

    FBLog(@"球建好了：直径=%.0f 窗口边长=%.0f view=%@ 自带手势=%lu 个",
          ball, [self windowSide], NSStringFromCGRect(self.view.bounds),
          (unsigned long)[_ball.gestureRecognizers count]);
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    FBLog(@"球露面了 window.frame=%@", NSStringFromCGRect(self.view.window.frame));
    notify_post(NOTIFY_LAUNCHED_HUD);
}

// ============================================================================
// 0.1.22：快捷菜单浮层（双击球就弹在球旁边，不用打开 App）
//
// 为什么要有它：原来 `action:openAppList` 的实现只是「往设置里写个 PendingTab，
// 再把 App 从 root 进程拉起来切到第 2 栏」—— 那不是全局浮层（用户要的是球旁边
// 直接弹出来、点一下就执行），而且它还依赖 FBOpenApplication 从 root 拉起 App，
// 那条路在 iOS 15 上经常被系统拒（用户实测「双击之后没有任何反应」）。
// 浮层完全在 HUD 进程里画，**不经过 App、不经过 LSApplicationWorkspace**。
//
// 排列：**竖排**，贴着球的那一侧（球在屏幕右半边就往左弹，反之往右弹），
// 这样菜单不会被系统刘海/圆角切掉。每项一行：图标 + 标题。
// 点菜单外面关掉菜单（这一下由 HUDApp 的 gFBConsumeWholeScreen 接管）。
// ============================================================================

/// 菜单里的一项。点它就把 key 交给 BallRootViewController 去执行。

#pragma mark - 快捷菜单浮层（0.1.22）

/// 从共享设置里读 App 那边存的快捷列表。
/// 存的是 plist 的 `Shortcuts` 键：`[["kind":"app|action|url","id":...,"title":...,"icon":...]]`
/// （格式见 ShortcutStore.swift，两边必须对齐 —— 改那边记得改这里）
- (NSArray<FBQuietMenuItem *> *)loadMenuItems
{
    NSMutableArray<FBQuietMenuItem *> *out = [NSMutableArray array];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:USER_DEFAULTS_PATH];
    NSArray *raw = d[@"Shortcuts"];
    if (![raw isKindOfClass:[NSArray class]]) return out;

    for (id row in raw) {
        if (![row isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *r = row;
        NSString *kind = r[@"kind"];
        NSString *rid  = r[@"id"];
        NSString *title = r[@"title"];
        if (![kind isKindOfClass:[NSString class]] ||
            ![rid isKindOfClass:[NSString class]] || rid.length == 0) continue;

        FBQuietMenuItem *item = [[FBQuietMenuItem alloc] init];
        item.key = [NSString stringWithFormat:@"%@:%@", kind, rid];
        item.title = [title isKindOfClass:[NSString class]] ? title : rid;

        // 图标：自定义的用存的；内置动作按 rawValue 映射（和 ShortcutAction.symbol 对齐）
        id icon = r[@"icon"];
        item.symbol = ([icon isKindOfClass:[NSString class]] && [icon length] > 0) ? icon
                    : [self symbolForActionId:rid];

        [out addObject:item];
        if (out.count >= (NSUInteger)kMenuMaxRows) break;   // 菜单放不下更多
    }
    return out;
}

/// 内置动作的 SF Symbol（对应 ShortcutAction.symbol；写全是因为 HUD 那边看不到 Swift）
- (NSString *)symbolForActionId:(NSString *)actionId
{
    static NSDictionary *map = nil;
    if (!map) {
        map = @{ @"refreshSignal": @"antenna.radiowaves.left.and.right",
                 @"goBack":        @"arrow.uturn.backward",
                 @"screenshot":    @"camera.viewfinder",
                 @"openMainApp":   @"app.badge",
                 @"openAppList":   @"square.grid.2x2",
                 @"moveBall":      @"hand.draw",
                 @"toggleLabel":   @"number",
                 @"none":          @"minus.circle" };
    }
    return map[actionId] ?: @"circle";
}

- (void)toggleQuickMenu
{
    if (_menuView) { [self closeQuickMenu]; return; }
    [self openQuickMenu];
}

- (void)openQuickMenu
{
    NSArray<FBQuietMenuItem *> *items = [self loadMenuItems];
    if (items.count == 0) {
        FBLog(@"菜单是空的（设置里还没加过任何快捷项）—— 先去 App 的「快捷菜单」页加几个");
        return;
    }
    _menuItems = items;

    FBQuietMenuView *menu = [[FBQuietMenuView alloc] initWithItems:items];
    menu.menuTapHandler = self;

    // ---- 摆位：竖排，贴在球那一侧（球在右半边就往左弹，反之往右弹）----
    CGFloat mh = CGRectGetHeight(menu.frame);
    CGRect sb = [self screenBounds];

    CGFloat mx;
    if (CGRectGetMidX(_ball.frame) > CGRectGetMidX(sb) / 2.0) {
        mx = CGRectGetMinX(_ball.frame) - kMenuGapFromBall - kMenuWidth;   // 球在右 → 菜单往左
    } else {
        mx = CGRectGetMaxX(_ball.frame) + kMenuGapFromBall;                // 球在左 → 菜单往右
    }
    // 贴边保护：别顶出屏幕
    mx = MAX(6.0, MIN(mx, CGRectGetMaxX(sb) - kMenuWidth - 6.0));

    // 竖排贴着球：菜单垂直居中对齐球心，然后夹进屏幕
    CGFloat my = CGRectGetMidY(_ball.frame) - mh / 2.0;
    my = MAX(56.0, MIN(my, CGRectGetMaxY(sb) - mh - 20.0));

    menu.frame = CGRectMake(mx, my, kMenuWidth, mh);
    _menuView = menu;
    [self.view addSubview:menu];

    // ⚠️ 关键：根视图的「可吃触摸区域」要**同时**包含球和菜单。
    // FBPassThroughView.pointInside: 只认一个 interactiveSubview，
    // 这里把它的 frame 换成「球 ∪ 菜单」的包围矩形 ——
    // 这样 [window hitTest:] 才可能落到菜单里的那一行上（不然点击根本送不到菜单）。
    [self updatePassThroughRegion];

    // 告诉 HUD 的触摸回调：菜单占哪块（判定接管用），并且**整屏接管**，
    // 好接住「点菜单外面 → 关菜单」那一下。
    //
    // ⚠️ 0.1.29：矩形用 `menu.frame` 换算，**不要**用 `convertRect:menu.bounds` ——
    //    菜单出现动画是 0.86→1.0 的 transform，`convertRect:` 会把缩放算进去，
    //    存下来的矩形比真实菜单小一圈，靠近边缘的行会被判成「菜单外」。
    CGRect menuInWindow = [self.view convertRect:menu.frame toView:self.view.window];
    FBHUDSetMenuArea(menuInWindow);
    FBHUDSetMenuView(menu);
    FBHUDSetConsumeWholeScreen(YES);

    FBLog(@"菜单已打开：%lu 项，位置 %@", (unsigned long)items.count, NSStringFromCGRect(menu.frame));
}

- (void)closeQuickMenu
{
    if (!_menuView) return;
    FBQuietMenuView *menu = _menuView;
    _menuView = nil;
    _menuItems = nil;

    [self updatePassThroughRegion];
    FBHUDSetMenuArea(CGRectZero);
    FBHUDSetMenuView(nil);
    FBHUDSetConsumeWholeScreen(NO);

    [UIView animateWithDuration:0.12 animations:^{
        menu.alpha = 0.0;
        menu.transform = CGAffineTransformMakeScale(0.9, 0.9);
    } completion:^(BOOL finished) {
        [menu removeFromSuperview];
    }];
    FBLog(@"菜单已关闭");
}

/// 菜单里第 idx 项被点了
- (void)quickMenuDidSelectIndex:(NSInteger)idx
{
    if (idx < 0 || idx >= (NSInteger)_menuItems.count) return;
    FBQuietMenuItem *item = _menuItems[idx];
    NSString *key = item.key;
    [self closeQuickMenu];

    // 推迟一拍再执行：菜单关闭有 0.12 秒的动画，
    // 如果这一项绑的恰好是「打开快捷菜单」自己，立刻执行会把菜单又弹出来。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.14 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self performTargetKey:key];
    });
}

/// 根视图的可吃触摸区域：球 ∪ 菜单
- (void)updatePassThroughRegion
{
    if (![self.view isKindOfClass:[FBPassThroughView class]]) return;
    FBPassThroughView *ptv = (FBPassThroughView *)self.view;

    if (!_menuView) {
        ptv.interactiveSubview = _ball;
        return;
    }
    // 复用一个不显示的「区域视图」，frame = 球 ∪ 菜单，
    // 让 pointInside: 用它算（它只看 interactiveSubview 的 bounds）。
    // userInteractionEnabled=NO → 它自己不参与 hitTest，只是块「边界板」。
    if (!_passThroughRegion) {
        _passThroughRegion = [[UIView alloc] initWithFrame:CGRectZero];
        _passThroughRegion.userInteractionEnabled = NO;
        _passThroughRegion.backgroundColor = [UIColor clearColor];
    }
    if (!_passThroughRegion.superview) [self.view insertSubview:_passThroughRegion atIndex:0];
    _passThroughRegion.frame = CGRectUnion(_ball.frame, _menuView.frame);
    ptv.interactiveSubview = _passThroughRegion;
}

#pragma mark - 动作

- (void)onSingleTap:(UITapGestureRecognizer *)g
{
    // ⚠️ 0.1.22：菜单开着的时候，轻点的语义是「关掉菜单」，
    //    **不执行**单击绑定的动作 —— 否则用户想关菜单，结果顺手打开了设置。
    if (_menuView) {
        FBLog(@"轻点：菜单开着，按「关掉菜单」处理（不执行单击绑定）");
        [self closeQuickMenu];
        return;
    }
    // ⚠️⚠️ 0.1.19 重要更正：**这个回调有两来路**。
    //    ① 我们自己合成的触摸（HUDApp.mm → TSEventFetcher → sendEvent:）—— 这是常态；
    //    ② 极少数情况下系统真把触摸派发进窗口。
    //    原来 `FBProbeRealTapDidFire()` 在这里无脑调用，于是 ① 也把它涨上去了，
    //    而 `FBRealTouchWorks()` 又只看这个数 —— **合成触摸把自己熔断了**
    //    （第一次点成功 → 判定「真触摸通了」→ 从此不再喂合成触摸 → 球彻底死掉）。
    //    熔断判据已改成「系统真的问过命中测试 + 手势触发 + 都在 2 秒内」，
    //    这里保留调用没问题，但**别再把它当成「系统派发了触摸」的证据**。
    FBProbeRealTapDidFire();

    // ⚠️ 0.1.20 删掉这里的震动。原来这里有 `[self haptic:FBHapticTap]`，
    //    而**起手那一刻 `FBBallHapticTouchDown()` 已经震过一下**（HUDApp.mm 喂 Began 时调的）。
    //    单击手势要等双击判定失败才触发 ≈ 0.3 秒之后 —— 于是用户听到的是
    //    「按下去震一下 → 停半秒 → 又震一下」，两下还强度不同（轻/轻），
    //    听起来像两次不相干的敲门，又拖沓又错位（用户 2026-10-18 原话：「比较拖拉的
    //    2 次震动 … 突兀和不一致的错位感」）。
    //    现在「按下去震一下 + 缩一下」就是这一下的全部反馈，唯一且跟手。
    //    真正**执行**了动作时才给 `FBHapticAction`（比如移动模式进出、显示/隐藏数字）。

    // 计数 +1 是「点到了」的证据：球浮在别的 App 上面时，这是唯一看得见的回执。
    // 真正干什么由设置里的「单击」绑定决定（默认 = 打开设置）。
    NSInteger count = [_prefs[@"TapCount"] integerValue] + 1;
    _prefs[@"TapCount"] = @(count);
    [self savePrefs];
    [self refreshLabel];

    // 「关于」页的自喂测试（0.1.14）：计数、震一下、标签变 —— 都照做（这就是「有反应」的可见证据），
    // 但**不执行**绑定动作（否则点一下「测试」会顺手打开设置 App，容易吓人）。
    if (gFBSelfTestTapPending) {
        gFBSelfTestTapPending = NO;
        FBLog(@"[自喂测试] 成功：球的手势认出来了（计数=%ld，未执行绑定动作）", (long)count);
        return;
    }

    if (_moveMode) {
        // 移动模式下轻点 = 退出移动模式，**不**执行绑定动作
        // （否则想挪球、结果顺手打开了别的 App）
        FBLog(@"轻点：退出移动模式");
        [self setMoveMode:NO];
        return;
    }

    NSString *target = [self gestureTarget:@"GestureTap"];
    FBLog(@"轻点：计数=%ld 绑定=%@", (long)count, target);
    [self performTargetKey:target];
}

#pragma mark - 绑定动作

/// 读某个手势绑的是什么；没设过就用默认值（和 ShortcutStore.swift 的 gestureDefaults 一致）
- (NSString *)gestureTarget:(NSString *)key
{
    NSString *value = _prefs[key];
    if ([value isKindOfClass:[NSString class]] && value.length > 0) return value;

    NSDictionary *defaults = @{ @"GestureTap":       @"app:com.apple.Preferences",
                                @"GestureDoubleTap": @"action:none",
                                @"GestureLongPress": @"action:moveBall" };
    return defaults[key] ?: @"action:none";
}

/// 绑定只存三种写法："app:bundleID" / "action:动作名" / "url:整条URL"
- (void)performTargetKey:(NSString *)key
{
    if (key.length == 0) return;

    if ([key hasPrefix:@"app:"]) {
        NSString *bundleID = [key substringFromIndex:4];
        BOOL ok = FBOpenApplication(bundleID);
        FBLog(@"绑定动作=打开 App %@ -> %@", bundleID, ok ? @"成功" : @"失败");
        return;
    }

    if ([key hasPrefix:@"url:"]) {
        // URL 协议 / 系统快捷指令：交给系统打开（和 App 里「快捷菜单」点一下同一条路）
        NSString *url = [key substringFromIndex:@"url:".length];
        BOOL ok = FBOpenURL(url);
        FBLog(@"绑定动作=打开 URL %@ -> %@", url, ok ? @"已交给系统" : @"打不开");
        return;
    }

    if ([key hasPrefix:@"action:"]) {
        [self performAction:[key substringFromIndex:@"action:".length]];
        return;
    }

    FBLog(@"⚠️ 认不出的绑定写法：%@", key);
}

- (void)performAction:(NSString *)action
{
    if ([action isEqualToString:@"none"]) {
        return;
    }

    if ([action isEqualToString:@"refreshSignal"]) {
        // ⚠️ 这个 API 没有结果：只是把请求交给 CommCenter。
        //    成没成只能看状态栏信号格，日志里看不出成败。
        //    所以只用「通知」那种震感表示「已经交代出去了」，不表示真的成功。
        [self haptic:FBHapticNotice];
        BOOL sent = FBRefreshCellularSignal();
        FBLog(@"绑定动作=刷新信号 -> %@", sent ? @"请求已发出（看信号格）" : @"发不出去");
        return;
    }

    if ([action isEqualToString:@"openAppList"]) {
        // ⚠️ 0.1.22：改成弹**球旁边的浮层**，不再「打开 App 到第 2 栏」。
        //    原来那条要靠 FBOpenApplication 从 root 进程把 App 拉起来，
        //    iOS 15 上经常被系统拒（用户实测「双击之后没有任何反应」），
        //    而且它本身也不是用户要的东西（用户要的是球旁边直接弹出来、能点的）。
        [self toggleQuickMenu];
        return;
    }

    if ([action isEqualToString:@"openMainApp"]) {
        [self requestAppTab:NO];
        return;
    }

    if ([action isEqualToString:@"moveBall"]) {
        [self setMoveMode:!_moveMode];
        return;
    }

    if ([action isEqualToString:@"toggleLabel"]) {
        [self toggleLabel];
        return;
    }

    if ([action isEqualToString:@"screenshot"]) {
        // 【截屏】两条路，先安全的、再兜底的（详见 FBSystemActions.mm 顶部那一段）：
        //   ① 系统自己的截图服务（ScreenshotServices，iOS 11 起截图能力就在那儿）——
        //      不注入任何输入，最安全；
        //   ② 不行就注入一次「音量加 + 电源」组合键（iOS 的截图快捷键）。
        [self haptic:FBHapticAction];
        int route = FBTakeScreenshot();
        FBLog(@"绑定动作=截屏 -> %@",
              route == 1 ? @"走系统截图服务（ScreenshotServices）"
            : route == 2 ? @"走按键注入（音量加 + 电源）"
            : @"没截成（两条路都没走通；若是系统说「现在不允许截屏」，那就是被屏幕使用时间之类的限制挡了，按设计不会硬来。原因看上一行日志）");
        return;
    }

    if ([action isEqualToString:@"goBack"]) {
        // 【全局返回】= 往系统注入一次「左缘往右划」，等于用户按了「上一页」。
        // ⚠️ 这是全项目唯一一个能伤到系统本身的动作（见 FBSystemActions.mm 顶部那三条保命写法）。
        // 球的屏幕矩形必须传进去：落点要避开球自己，
        // 否则球会把自己注入的划动当成「用户在拖它」（球乱跑，甚至自己触发自己）。
        CGRect ballOnScreen = CGRectZero;
        if (_ball && _ball.window) {
            CGRect inWindow = [_ball convertRect:_ball.bounds toView:_ball.window];
            ballOnScreen = CGRectOffset(inWindow, _ball.window.frame.origin.x, _ball.window.frame.origin.y);
            ballOnScreen = CGRectInset(ballOnScreen, -10.0, -10.0);   // 多留一点余量
        }
        BOOL sent = FBGoBack(ballOnScreen);
        FBLog(@"绑定动作=全局返回 -> %@",
              sent ? @"已注入左缘右划（看界面回没回上一页）" : @"没注进去（原因看上一行日志）");
        return;
    }

    FBLog(@"⚠️ 认不出的动作：%@", action);
}

/// 「打开悬浮球 App」和「打开快捷菜单」共用：
/// 先往共享设置里写一个「App 起来后落在哪一栏」，再把 App 拉起来。
///
/// 为什么不用 URL scheme：这样不用往 Info.plist 加东西，
/// 而且 App **没在跑**时也生效（App 启动时会读这个键，读完就清掉）。
/// App 正在后台跑时，它回到前台会再读一次 —— 两条路都覆盖到了。
- (void)requestAppTab:(BOOL)showAppList
{
    _prefs[@"PendingTab"] = showAppList ? @"apps" : @"launch";
    [self savePrefs];

    BOOL ok = FBOpenApplication(OWN_BUNDLE_ID);
    FBLog(@"绑定动作=打开悬浮球（落点=%@）-> %@",
          showAppList ? @"快捷菜单" : @"启动页", ok ? @"成功" : @"失败");
}

- (void)toggleLabel
{
    _showText = !_showText;
    _prefs[@"ShowLabel"] = @(_showText);
    [self savePrefs];
    [self refreshLabel];
    [self haptic:FBHapticAction];   // 状态变了，给个「中」的反馈
    FBLog(@"绑定动作=显示数字 -> %@", _showText ? @"开" : @"关");
}

/// 移动模式：球高亮一圈，拖一下就落位，点一下退出。
/// （拖动本来就一直能用，这个模式是给「怕误触」的人用的：
///   进入后轻点不会触发绑定动作，只会退出。）
- (void)setMoveMode:(BOOL)on
{
    if (_moveMode == on) return;
    _moveMode = on;
    [self haptic:FBHapticAction];

    if (on) {
        _ball.layer.borderWidth = 3.0;
        _ball.layer.borderColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.95].CGColor;
        FBLog(@"进入移动模式（拖球落位；点一下 = 退出）");
    } else {
        // 还原成「该有的样子」：正常贴图没有描边，退化成纯色球时才留一圈
        _ball.layer.borderWidth = _fallbackBall ? 1.0 : 0.0;
        _ball.layer.borderColor = _fallbackBall
            ? [UIColor colorWithWhite:1.0 alpha:0.35].CGColor
            : nil;
        FBLog(@"退出移动模式");
    }
    [self refreshLabel];
}

#pragma mark - 打开别的 App

- (BOOL)openApplication:(NSString *)bundleID
{
    // 实现搬到 FBSystemActions.mm 了：App 侧（快捷列表里点一行）也要用同一份。
    // 那边是 dlsym + objc_getClass 的写法，不链接任何私有符号。
    return FBOpenApplication(bundleID);
}

- (void)onDoubleTap:(UITapGestureRecognizer *)g
{
    if (_moveMode) { [self setMoveMode:NO]; return; }

    // ⚠️ 0.1.22：双击默认直接开/关菜单浮层，不再绕「打开 App 到第 2 栏」那条路
    //    （用户实测那条没反应：它依赖 FBOpenApplication 从 root 进程拉起 App，
    //    iOS 15 上经常被系统拒；而它就算成功也只是「打开 App」，不是用户要的浮层）。
    //    仍然尊重用户自己的绑定：绑成别的就照旧走绑定。
    NSString *target = [self gestureTarget:@"GestureDoubleTap"];
    if ([target isEqualToString:@"action:openAppList"]) {
        FBLog(@"双击：切换快捷菜单浮层");
        [self toggleQuickMenu];
        return;
    }

    FBLog(@"双击：绑定=%@", target);
    // ⚠️ 0.1.20 同样删掉 `haptic:FBHapticTap` —— 双击的第二次「按下」起手时已经震过了，
    //    再补一下就是「双击听到四下」。（单击那处的原因写在 onSingleTap: 上面。）
    [self performTargetKey:target];
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (_moveMode) { [self setMoveMode:NO]; return; }

    NSString *target = [self gestureTarget:@"GestureLongPress"];
    FBLog(@"长按：绑定=%@", target);
    // 长按这里给「中」那一档而不是不再给：按下那一下是「轻」，0.5 秒后动作真的开始
    // 是另一回事，用不同强度区分开（两下挨太近的话用户自己会提，别自作主张）。
    [self haptic:FBHapticAction];
    [self performTargetKey:target];
}

- (void)onPan:(UIPanGestureRecognizer *)g
{
    if (!_ball) return;

    // ⚠️ 0.1.22：菜单开着的时候**先关菜单**，不拖球。
    //    （否则想点菜单项、结果把球拖走了 —— 菜单浮层最忌讳这个。）
    if (_menuView) {
        if (g.state == UIGestureRecognizerStateBegan) {
            FBLog(@"拖动：菜单开着，按「关掉菜单」处理（不挪球）");
            [self closeQuickMenu];
        }
        return;
    }

    // ⚠️ 0.1.18：窗口是全屏的、不跟着手指走 —— 直接按**根视图坐标（= 屏幕坐标）**移动球。
    //    （以前是移动窗口，还得每帧把窗口坐标换算回屏幕坐标，那个反馈环的坑现在不存在了。）
    CGPoint p = [g locationInView:self.view];

    if (g.state == UIGestureRecognizerStateBegan) {
        _grabOffset = CGPointMake(p.x - _ball.center.x, p.y - _ball.center.y);
    } else if (g.state == UIGestureRecognizerStateChanged) {
        // 空点 / 跑到屏幕外的坐标一律忽略（0.1.17 那两道闸保留）
        CGRect sb = [self screenBounds];
        if (p.x <= 1.0 && p.y <= 1.0) return;
        if (!CGRectContainsPoint(CGRectInset(sb, -40.0, -40.0), p)) return;

        CGPoint c = CGPointMake(p.x - _grabOffset.x, p.y - _grabOffset.y);
        _ball.center = [self clampedCenter:c];
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        FBLog(@"拖动结束，球心=(%.0f,%.0f)", _ball.center.x, _ball.center.y);
        [self haptic:FBHapticTap];   // 松手那一下轻震：告诉用户「落这儿了」
        [self snapToEdge];
        // 移动模式：拖完就自动退出，不用再点一下
        if (_moveMode) [self setMoveMode:NO];
    }
}

- (void)snapToEdge
{
    if (!_ball) return;

    CGRect sb = [self screenBounds];
    CGFloat half = [self ballSize] / 2.0;
    CGPoint c = _ball.center;
    CGFloat targetX = (c.x < CGRectGetMidX(sb)) ? half : CGRectGetMaxX(sb) - half;
    CGFloat targetY = MAX(half, MIN(c.y, CGRectGetMaxY(sb) - half));

    [UIView animateWithDuration:0.2 delay:0.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_ball.center = CGPointMake(targetX, targetY);
    } completion:^(BOOL finished) {
        [self persistPosition];
    }];
}

- (void)persistPosition
{
    if (!_ball) return;
    _prefs[@"BallX"] = @(_ball.center.x);
    _prefs[@"BallY"] = @(_ball.center.y);
    [self savePrefs];
    FBLog(@"位置已存：球心=(%.0f, %.0f)", _ball.center.x, _ball.center.y);
}

#pragma mark - 视图刷新

/// 重新应用外观。
/// - Returns: 0.1.21 起返回 BOOL —— `YES` = 真的拿到图了（或者本来就该走兜底路径）；
///                `NO` = 贴图读不出来（多半是另一个进程正在改写它），调用方据此决定要不要重试。
- (BOOL)applyBallStyle
{
    // 贴图由 App 那边按「形状 + 颜色 + 自定义图」画好写到公共路径（见 BallRenderer.swift），
    // 这里只负责读文件显示 —— 画图代码只有一处，预览和实际不会不一致。
    BOOL applied = YES;   // 0.1.21
    UIImage *image = [UIImage imageWithContentsOfFile:BALL_IMAGE_PATH];
    NSString *source = @"App 画的贴图";
    if (!image) {
        // 兜底：App 还没打开过时这个文件还不存在，用包里那张默认小圆点
        image = [UIImage imageNamed:kDefaultBallStyle];
        source = @"包里的默认小圆点";
    }

    if (image) {
        _ball.image = image;
        _ball.backgroundColor = [UIColor clearColor];
        _ball.layer.borderWidth = 0.0;
        _fallbackBall = NO;
        FBLog(@"球贴图=%@（%.0fx%.0f）", source, image.size.width, image.size.height);
    } else {
        // 两条路都拿不到图也得有个球，否则「球没出来」和「贴图丢了」分不清
        _ball.image = nil;
        _ball.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        _ball.layer.borderWidth = 1.0;
        _ball.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
        _fallbackBall = YES;
        FBLog(@"⚠️ 没有任何贴图（%@ 和包里的默认图都不在），退化成纯色球", BALL_IMAGE_PATH);
        applied = NO;   // 0.1.21：告诉调用方这一轮没拿到图，让它别把基准记死
    }

    // 移动模式的高亮圈不能被「重设样式」抹掉
    if (_moveMode) {
        _ball.layer.borderWidth = 3.0;
        _ball.layer.borderColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.95].CGColor;
    }

    // 不透明度：夹在 0.3~1.0，手改 plist 也不至于把球调成看不见
    CGFloat opacity = 1.0;
    NSNumber *stored = _prefs[@"BallOpacity"];
    if ([stored isKindOfClass:[NSNumber class]]) {
        opacity = MAX(0.3, MIN(1.0, [stored doubleValue]));
    }
    _ball.alpha = opacity;

    [self updateShadowPath];
    [self writeStyleDiag:source];
    return applied;   // 0.1.21
}

- (void)updateShadowPath
{
    // 阴影要按「圆形路径」给：默认按 bounds 算会露出四个角的方影
    _ball.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:_ball.bounds].CGPath;
}

- (void)refreshLabel
{
    // 移动模式下先不显示数字：让用户知道「现在拖得动」
    _label.hidden = !_showText || _moveMode;
    _label.text = [NSString stringWithFormat:@"%ld", (long)[_prefs[@"TapCount"] integerValue]];
    // ⚠️ 0.1.20：用户反馈「点了之后数字看着没变，切到别的 tab 再回来才发现 +1 了」。
    //    UILabel 换 text 会自己 setNeedsDisplay，但我们在的是一个**影子 UIApplication**
    //    （没有 SpringBoard 的渲染循环替我们提交），所以这里显式刷一次。
    //    刷新条件里对比一下旧值：没变就不刷，省掉无谓的重绘。
    if (![_label.text isEqualToString:[NSString stringWithFormat:@"%ld",
                                       (long)[_prefs[@"TapCount"] integerValue]]]) {
        [_label setNeedsDisplay];
        [_label setNeedsLayout];
        [_label.layer setNeedsDisplay];
    }
}

- (void)applyLayout
{
    // ⚠️ 0.1.18：窗口是全屏的，**球在窗口里移动**（以前是移动窗口）。
    CGFloat ball = [self ballSize];

    CGPoint center = _ball.center;
    // ⚠️ 0.1.19：原来是 `if (center.x <= 0.0 && center.y <= 0.0)`。
    //    球被 clamp 到屏幕左上角时 center.x 恰好是 0（半径），
    //    但 y 通常不是 0 —— 于是「只在左边缘」这一种最常见的贴边位置
    //    每秒被重算成默认位置（右侧中部），球会自己跑掉。
    //    「还没定位过」的条件应该是**任一**坐标无效。
    if (center.x <= 0.0 || center.y <= 0.0) {
        center = [self initialCenter];
    }
    center = [self clampedCenter:center];

    _ball.frame = CGRectMake(center.x - ball / 2.0, center.y - ball / 2.0, ball, ball);
    _ball.layer.cornerRadius = ball / 2.0;
    _label.frame = _ball.bounds;
    _label.font = [UIFont systemFontOfSize:MAX(11.0, ball * 0.32) weight:UIFontWeightSemibold];
    [self updateShadowPath];
}

- (void)reloadSettings
{
    [self loadPrefs];
    [self applyBallStyle];   // 样式可能被改了，先换图再排布局
    [self applyLayout];

    // App 那边点了「复位位置」：BallX/BallY 写成 -1
    NSNumber *x = _prefs[@"BallX"];
    NSNumber *y = _prefs[@"BallY"];
    CGPoint center = (x && y && [x doubleValue] >= 0 && [y doubleValue] >= 0)
        ? CGPointMake([x doubleValue], [y doubleValue])
        : [self defaultCenter];

    // 0.1.18：窗口是全屏的，位置只作用于**球**
    center = [self clampedCenter:center];
    if (_ball) {
        _ball.center = center;
    }

    // 数字显不显示也可能被改了（App 那边的「显示/隐藏数字」动作）
    NSNumber *showLabel = _prefs[@"ShowLabel"];
    if (showLabel) _showText = [showLabel boolValue];

    [self refreshLabel];
}

@end
