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

// 默认值
static const CGFloat kDefaultBallSize = 56.0;
static const CGFloat kWindowPadding = 12.0;   // 窗口比球大一圈：给阴影和手指宽容区
static NSString *const kDefaultBallStyle = @"BallDot";   // 贴图名（见 scripts/make_icon.py）

// ---- 震动反馈 ----
//
// 开关存在共享设置里（App 首页那个「震动反馈」开关，键 = HapticsEnabled，默认开）。
// App 那边有一份等价实现（src/controllers/Haptics.swift）——
// 改键名 / 默认值 / 震感，两边必须一起改。
//
// ⚠️ 手机上「设置 → 声音与触感 → 系统触感反馈」关掉的话，这里全部没感觉。
//    那是系统总开关，绕不过去（App 界面上有提示）。
typedef NS_ENUM(NSInteger, FBHapticKind) {
    FBHapticTap = 0,   // 识别到点击 / 球落位                —— 轻
    FBHapticAction,    // 动作真的执行了（移动模式、数字开关）—— 中
    FBHapticNotice,    // 「交代出去一件事」（刷新信号）      —— 通知那种两下
};

static void FBHapticPlay(FBHapticKind kind)
{
    // ⚠️ 不用单例生成器：两次手势之间可能隔很久，生成器会凉掉。
    //    每次新建 + prepare 的响应最稳。
    if (kind == FBHapticNotice) {
        UINotificationFeedbackGenerator *g = [[UINotificationFeedbackGenerator alloc] init];
        [g prepare];
        [g notificationOccurred:UINotificationFeedbackTypeSuccess];
        return;
    }

    UIImpactFeedbackStyle style = (kind == FBHapticAction)
        ? UIImpactFeedbackStyleMedium
        : UIImpactFeedbackStyleLight;
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [g prepare];
    [g impactOccurred];
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
    return CGRectContainsPoint(touchable, point);
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

/// 走开关的震动：设置里 `HapticsEnabled` 是 false 就什么都不做。
/// ⚠️ 用「没设过 = 开」的语义：老版本升上来时这个键不存在，不该变成静音。
- (void)haptic:(FBHapticKind)kind
{
    NSNumber *on = _prefs[@"HapticsEnabled"];
    if ([on isKindOfClass:[NSNumber class]] && ![on boolValue]) return;
    FBHapticPlay(kind);
}

#pragma mark - 设置（和 App 共享 /var/mobile/Library/Preferences 下同一个 plist）

- (void)loadPrefs
{
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:USER_DEFAULTS_PATH];
    _prefs = onDisk ? [onDisk mutableCopy] : [NSMutableDictionary dictionary];
    if (!_prefs[@"BallSize"])  _prefs[@"BallSize"]  = @(kDefaultBallSize);
    if (!_prefs[@"TapCount"])  _prefs[@"TapCount"]  = @0;
}

- (void)savePrefs
{
    NSDictionary *snapshot = [_prefs copy];
    [snapshot writeToFile:USER_DEFAULTS_PATH atomically:YES];
}

- (CGFloat)ballSize
{
    NSNumber *n = _prefs[@"BallSize"];
    CGFloat size = n ? [n doubleValue] : kDefaultBallSize;
    return MAX(24.0, MIN(size, 160.0));
}

- (CGFloat)windowSide
{
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
    CGFloat half = [self windowSide] / 2.0;
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
    [self loadPrefs];

    // 数字显示不显示，存在共享设置里（App 那边的「显示/隐藏数字」动作也改这个键）
    NSNumber *showLabel = _prefs[@"ShowLabel"];
    _showText = showLabel ? [showLabel boolValue] : YES;

    self.view.backgroundColor = [UIColor clearColor];

    CGFloat side = [self windowSide];
    CGFloat ball = [self ballSize];

    // 球本体用贴图（样式可以在 App 里换），贴图由 scripts/make_icon.py 生成。
    // 用贴图而不是纯色 + 描边，是为了「桌面图标」「屏幕上的球」长得一模一样。
    _ball = [[UIImageView alloc] initWithFrame:CGRectMake((side - ball) / 2.0, (side - ball) / 2.0, ball, ball)];
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

    FBLog(@"球建好了：直径=%.0f 窗口边长=%.0f view=%@ 自带手势=%lu 个",
          ball, side, NSStringFromCGRect(self.view.bounds),
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
    // 计数 +1 是「点到了」的证据：球浮在别的 App 上面时，这是唯一看得见的回执。
    // 真正干什么由设置里的「单击」绑定决定（默认 = 打开设置）。
    NSInteger count = [_prefs[@"TapCount"] integerValue] + 1;
    _prefs[@"TapCount"] = @(count);
    [self savePrefs];
    [self refreshLabel];
    [self haptic:FBHapticTap];

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

/// 绑定只存两种写法："app:bundleID" / "action:动作名"
- (void)performTargetKey:(NSString *)key
{
    if (key.length == 0) return;

    if ([key hasPrefix:@"app:"]) {
        NSString *bundleID = [key substringFromIndex:4];
        BOOL ok = FBOpenApplication(bundleID);
        FBLog(@"绑定动作=打开 App %@ -> %@", bundleID, ok ? @"成功" : @"失败");
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

    FBLog(@"⚠️ 认不出的动作：%@", action);
}

/// 「打开悬浮球 App」和「打开快捷列表」共用：
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
          showAppList ? @"快捷列表" : @"启动页", ok ? @"成功" : @"失败");
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
    UIWindow *window = self.view.window;
    if (!window) return;

    // 窗口内坐标 -> 屏幕坐标（窗口跟着手指走，所以必须每帧换算，见文件头注释）
    CGPoint inWindow = [g locationInView:nil];
    CGPoint onScreen = CGPointMake(window.frame.origin.x + inWindow.x,
                                   window.frame.origin.y + inWindow.y);

    if (g.state == UIGestureRecognizerStateBegan) {
        _grabOffset = CGPointMake(onScreen.x - window.frame.origin.x,
                                  onScreen.y - window.frame.origin.y);
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGRect f = window.frame;
        f.origin = CGPointMake(onScreen.x - _grabOffset.x, onScreen.y - _grabOffset.y);
        window.frame = f;
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        // 只在收尾时记一行：拖动过程中每个事件都记会把日志刷爆
        FBLog(@"拖动结束，落点 frame=%@", NSStringFromCGRect(window.frame));
        [self haptic:FBHapticTap];   // 松手那一下轻震：告诉用户「落这儿了」
        [self snapToEdge];
        // 移动模式：拖完就自动退出，不用再点一下
        if (_moveMode) [self setMoveMode:NO];
    }
}

- (void)snapToEdge
{
    UIWindow *window = self.view.window;
    if (!window) return;

    CGRect sb = [self screenBounds];
    CGRect f = window.frame;
    CGFloat targetX = (CGRectGetMidX(f) < CGRectGetMidX(sb))
        ? 0.0
        : CGRectGetMaxX(sb) - f.size.width;
    CGFloat targetY = MAX(0.0, MIN(f.origin.y, CGRectGetMaxY(sb) - f.size.height));

    [UIView animateWithDuration:0.2 delay:0.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        window.frame = CGRectMake(targetX, targetY, f.size.width, f.size.height);
    } completion:^(BOOL finished) {
        [self persistPosition];
    }];
}

- (void)persistPosition
{
    UIWindow *window = self.view.window;
    if (!window) return;
    _prefs[@"BallX"] = @(CGRectGetMidX(window.frame));
    _prefs[@"BallY"] = @(CGRectGetMidY(window.frame));
    [self savePrefs];
    FBLog(@"位置已存：球心=(%.0f, %.0f)", CGRectGetMidX(window.frame), CGRectGetMidY(window.frame));
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
    UIWindow *window = self.view.window;
    if (!window) return;

    CGFloat side = [self windowSide];
    CGFloat ball = [self ballSize];

    CGPoint center = CGPointMake(CGRectGetMidX(window.frame), CGRectGetMidY(window.frame));
    center = [self clampedCenter:center];

    window.frame = CGRectMake(center.x - side / 2.0, center.y - side / 2.0, side, side);
    _ball.frame = CGRectMake((side - ball) / 2.0, (side - ball) / 2.0, ball, ball);
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

    UIWindow *window = self.view.window;
    if (window) {
        center = [self clampedCenter:center];
        CGRect f = window.frame;
        f.origin = CGPointMake(center.x - f.size.width / 2.0, center.y - f.size.height / 2.0);
        window.frame = f;
    }

    // 数字显不显示也可能被改了（App 那边的「显示/隐藏数字」动作）
    NSNumber *showLabel = _prefs[@"ShowLabel"];
    if (showLabel) _showText = [showLabel boolValue];

    [self refreshLabel];
}

@end
