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

#import "../helpers/private_headers/LSApplicationWorkspace.h"

// 0.1.16：这些方法互相调用，先声明一遍，省得编译器报「找不到方法」
@interface BallRootViewController ()
- (void)applyBallStyle;
- (void)applyLayout;
- (void)refreshLabel;
- (void)writeStyleDiag:(NSString *)source;
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
// ⚠️ 手机上「设置 → 声音与触感 → 系统触感反馈」关掉的话，这里全部没感觉。
//    那是系统总开关，绕不过去（App 界面上有提示）。
typedef NS_ENUM(NSInteger, FBHapticKind) {
    FBHapticTap = 0,   // 识别到点击 / 球落位                —— 轻
    FBHapticAction,    // 动作真的执行了（移动模式、数字开关）—— 中
    FBHapticNotice,    // 「交代出去一件事」（刷新信号）      —— 两下
};

// 震动参数（键名与 Haptics.swift 共用）：
//   强度 `HapticIntensity`  0.2~1.0（默认 1.0）→ 走 impactOccurredWithIntensity:
//   ~~时长 `HapticDurationMs`~~ —— **0.1.12 起作废**：用户实测「连敲拼时长」效果一般，
//        于是直接去掉，一律就系统默认那一下（≈40ms；Taptic 引擎敲一下的长度是系统定死的，
//        想精确到毫秒得用 CoreHaptics，而它要求 App 在前台 + 有音频会话，HUD 里不靠谱）。
//        ⚠️ 只有 `FBHapticNotice`（「交代出去一件事」）保留**两下** —— 那是信号，不是时长。
//        ⚠️ 老版本写进设置的 `HapticDurationMs` 现在**没人读**了（不用清，不影响）。
#define FBHapticPulseSpacingMs  40    // 两下之间隔多少毫秒（只给 notice 的两下用）

static UIImpactFeedbackGenerator *sHapticLight  = nil;
static UIImpactFeedbackGenerator *sHapticMedium = nil;

/// 球控制器（viewDidLoad 时登记），给 FBBallHapticTouchDown() 用的。
static BallRootViewController *sBallVC = nil;

/// 建好常驻生成器并提前预热（异步的，越早越好）。见 FBHapticPlay 的注释。
static void FBHapticWarmUp(void)
{
    if (!sHapticLight) {
        sHapticLight  = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        sHapticMedium = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    }
    [sHapticLight prepare];
    [sHapticMedium prepare];
}

/// 敲一下（强度来自设置）
static void FBHapticPulse(FBHapticKind kind, CGFloat intensity)
{
    if (kind == FBHapticTap) {
        [sHapticLight impactOccurredWithIntensity:intensity];
    } else {
        [sHapticMedium impactOccurredWithIntensity:intensity];
    }
}

/// - Parameters:
///   - kind:      震感种类（决定用轻 / 中生成器，以及敲几下）
///   - intensity: 0.2~1.0（设置里的「强度」）
///   ⚠️ 0.1.12 起没有「敲几下」这个入参了：时长不再可调，一律一下
///      （只有 `FBHapticNotice` 例外，见下）。
static void FBHapticPlay(FBHapticKind kind, CGFloat intensity)
{
    // ⚠️ 以前是「每次新建生成器 + prepare + 立刻震」—— 临时抱佛脚没用：
    //    prepare() 是**异步**预热振动引擎的，跟 impactOccurred 挤在同一个 tick 里，
    //    那一下照样是凉的。用户感觉就是「延迟几百毫秒、跟手性不够」。
    //    正解：生成器常驻、提前 prepare 好，震完再补一次保温（见 FBHapticWarmUp）。
    FBHapticWarmUp();

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

    // 震完立刻再预热一次，让引擎保持热的 —— 下一次按下去还是立刻有
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ FBHapticWarmUp(); });
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

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    if (!self.interactiveSubview) {
        return [super pointInside:point withEvent:event];
    }
    // 球本身再往外放 6pt，手指没那么准
    CGRect touchable = CGRectInset(self.interactiveSubview.frame, -6.0, -6.0);
    BOOL inside = CGRectContainsPoint(touchable, point);
    // 自检：窗口重新参与命中测试之后（0.1.8），这里每被问一次就说明
    //「**真有触摸问进这个窗口**」—— 这是判断这条路通没通的第一手证据。
    FBProbeTouchHit(inside);
    return inside;
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
}

#pragma mark - 震动

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
    NSNumber *on = _prefs[@"HapticsEnabled"];
    if ([on isKindOfClass:[NSNumber class]] && ![on boolValue]) return;

    // 0.1.16：诊断用 —— HUD 是后台进程，`UIImpactFeedbackGenerator` 的震动可能被系统吞掉。
    // 只记一次，别刷日志。
    static int sLoggedState = 0;
    if (!sLoggedState) {
        sLoggedState = 1;
        FBLog(@"震动：applicationState=%ld（后台时系统可能吞掉震动；这是第 0.1.16 版新加的诊断）",
              (long)[UIApplication sharedApplication].applicationState);
    }

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
    // 0.1.16：真机结论是**球进程里震动被系统吞了**（自喂测试：手势触发、计数+1，但没有震感）。
    // 所以再加一层**看得见**的反馈：球按下去缩一下 —— 这一层不依赖任何系统服务。
    [sBallVC haptic:FBHapticTap];
    [sBallVC pressFeedback];
}

/// 定时保温（每 2 秒一次）：球会一直挂在屏幕上、可能隔很久才被点一下，
/// 引擎一凉就变成「按下去半天才震」。走同一个开关：关掉震动就不保温。
- (void)warmHaptics
{
    // 0.1.16：顺手检查外观文件有没有变（0.1.16 用户反馈：改形状/颜色/大小/透明度都没反应）。
    // 通知有可能没送到（或送到时刚写了一半），所以每 2 秒比对一次文件修改时间 ——
    // plist 或贴图变了就重新应用，**不依赖通知**。
    [self pollAppearanceFiles];

    NSNumber *on = _prefs[@"HapticsEnabled"];
    if ([on isKindOfClass:[NSNumber class]] && ![on boolValue]) return;
    FBHapticWarmUp();
}

- (void)pollAppearanceFiles
{
    static NSTimeInterval lastCfg = -1, lastImg = -1;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *cfgAttrs = [fm attributesOfItemAtPath:USER_DEFAULTS_PATH error:NULL];
    NSDictionary *imgAttrs = [fm attributesOfItemAtPath:BALL_IMAGE_PATH error:NULL];
    NSTimeInterval cfg = [cfgAttrs[NSFileModificationDate] timeIntervalSince1970];
    NSTimeInterval img = [imgAttrs[NSFileModificationDate] timeIntervalSince1970];

    if (lastCfg < 0) {           // 第一次只记基准
        lastCfg = cfg;
        lastImg = img;
        return;
    }
    if (cfg == lastCfg && img == lastImg) return;

    FBLog(@"外观文件变了（plist %.0f→%.0f / 图 %.0f→%.0f），重新应用",
          lastCfg, cfg, lastImg, img);
    lastCfg = cfg;
    lastImg = img;

    [self loadPrefs];
    [self applyBallStyle];
    [self applyLayout];
    [self refreshLabel];
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

    // 振动：生成器常驻 + 每 2 秒保温一次，保证「按下去立刻有反馈」。
    // ⚠️ 以前是每次震的时候才新建生成器 + prepare —— 那一下引擎是凉的，
    //    用户感觉就是延迟几百毫秒、跟手性不够。
    FBHapticWarmUp();
    [NSTimer scheduledTimerWithTimeInterval:2.0
                                     target:self
                                   selector:@selector(warmHaptics)
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

#pragma mark - 动作

- (void)onSingleTap:(UITapGestureRecognizer *)g
{
    // 自检：这是「触摸真的落到球上、手势也认出来了」的证据（0.1.8）
    FBProbeRealTapDidFire();

    // 计数 +1 是「点到了」的证据：球浮在别的 App 上面时，这是唯一看得见的回执。
    // 真正干什么由设置里的「单击」绑定决定（默认 = 打开设置）。
    NSInteger count = [_prefs[@"TapCount"] integerValue] + 1;
    _prefs[@"TapCount"] = @(count);
    [self savePrefs];
    [self refreshLabel];
    [self haptic:FBHapticTap];

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

    if ([action isEqualToString:@"openMainApp"] || [action isEqualToString:@"openAppList"]) {
        [self requestAppTab:[action isEqualToString:@"openAppList"]];
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
            : @"两条路都没走通（原因看上一行日志）");
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

    NSString *target = [self gestureTarget:@"GestureDoubleTap"];
    FBLog(@"双击：绑定=%@", target);
    [self haptic:FBHapticTap];
    [self performTargetKey:target];
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (_moveMode) { [self setMoveMode:NO]; return; }

    NSString *target = [self gestureTarget:@"GestureLongPress"];
    FBLog(@"长按：绑定=%@", target);
    [self haptic:FBHapticTap];
    [self performTargetKey:target];
}

- (void)onPan:(UIPanGestureRecognizer *)g
{
    if (!_ball) return;

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

- (void)applyBallStyle
{
    // 贴图由 App 那边按「形状 + 颜色 + 自定义图」画好写到公共路径（见 BallRenderer.swift），
    // 这里只负责读文件显示 —— 画图代码只有一处，预览和实际不会不一致。
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
}

- (void)applyLayout
{
    // ⚠️ 0.1.18：窗口是全屏的，**球在窗口里移动**（以前是移动窗口）。
    CGFloat ball = [self ballSize];

    CGPoint center = _ball.center;
    if (center.x <= 0.0 && center.y <= 0.0) {
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
