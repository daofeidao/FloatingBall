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

#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#import "../helpers/private_headers/LSApplicationWorkspace.h"

// 默认值
static const CGFloat kDefaultBallSize = 56.0;
static const CGFloat kWindowPadding = 12.0;   // 窗口比球大一圈：给阴影和手指宽容区
static NSString *const kDefaultBallStyle = @"BallDot";   // 贴图名（见 scripts/make_icon.py）

static void LightHaptic(void)
{
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
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
    BOOL _showText;           // 长按切换：显示计数 / 只显示一个点
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
    _showText = YES;

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
    // v0.1 的验收点：能点中就说明触摸进来了。
    // 计数 +1 是「点到了」的证据，同时顺手打开「设置」当动作示例。
    NSInteger count = [_prefs[@"TapCount"] integerValue] + 1;
    _prefs[@"TapCount"] = @(count);
    [self savePrefs];
    [self refreshLabel];
    LightHaptic();

    BOOL opened = [self openApplication:@"com.apple.Preferences"];
    FBLog(@"轻点：计数=%ld，打开设置=%@", (long)count, opened ? @"成功" : @"失败");
}

#pragma mark - 打开别的 App

- (BOOL)openApplication:(NSString *)bundleID
{
    // ⚠️ 这里**故意**不写 [LSApplicationWorkspace defaultWorkspace]。
    //    直接写类名会让链接期要求解析私有 framework 的类符号；
    //    用 objc_getClass 拿到的只是一个字符串查找，永远不会链接失败。
    //    （Helium 访问这个类也是这么写的，照抄它。）
    Class wsClass = objc_getClass("LSApplicationWorkspace");
    if (wsClass) {
        id ws = [(id)wsClass performSelector:@selector(defaultWorkspace)];
        SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (ws && [ws respondsToSelector:openSel]) {
            // ⚠️ 这里必须用 objc_msgSend + 显式函数指针，不能写 performSelector：
            //    performSelector 的返回类型是 id，ARC 会把 BOOL 的 0x1 当对象去 retain → 崩。
            BOOL (*openApp)(id, SEL, NSString *) = (BOOL (*)(id, SEL, NSString *))objc_msgSend;
            if (openApp(ws, openSel, bundleID)) return YES;
        }
    }

    // 兜底：SpringBoardServices 的 C 接口（TheBall 用的就是这条路）。
    // ⚠️ 用 dlsym 在运行时查，**不要**直接调用 ——
    //    直接调用会让链接期去 SDK 的私有 stub 里找符号，
    //    找不到就是 undefined symbol 编译失败；dlsym 找不到只是返回 NULL。
    typedef int (*SBSLaunchFn)(NSString *, NSDictionary *, NSDictionary *, BOOL);
    static SBSLaunchFn launchFn = NULL;
    static dispatch_once_t launchOnce;
    dispatch_once(&launchOnce, ^{
        launchFn = (SBSLaunchFn)dlsym(RTLD_DEFAULT, "SBSLaunchApplicationWithIdentifierAndLaunchOptions");
    });

    if (launchFn) {
        int rc = launchFn(bundleID, @{}, @{}, NO);
        if (rc != 0) {
            os_log_error(OS_LOG_DEFAULT, "打开 %{public}@ 失败，rc=%d", bundleID, rc);
        }
        return rc == 0;
    }

    os_log_error(OS_LOG_DEFAULT, "两条路都走不通，打不开 %{public}@", bundleID);
    return NO;
}

- (void)onDoubleTap:(UITapGestureRecognizer *)g
{
    // v0.1：双击先把计数清零（v0.2 起改成「用户自己绑定的动作」）
    FBLog(@"双击");
    _prefs[@"TapCount"] = @0;
    [self savePrefs];
    [self refreshLabel];
    LightHaptic();
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    FBLog(@"长按");
    _showText = !_showText;
    [self refreshLabel];
    LightHaptic();
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
        [self snapToEdge];
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
    NSString *name = _prefs[@"BallStyle"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) {
        name = kDefaultBallStyle;
    }

    UIImage *image = [UIImage imageNamed:name];
    if (image) {
        _ball.image = image;
        _ball.backgroundColor = [UIColor clearColor];
        _ball.layer.borderWidth = 0.0;
        FBLog(@"球样式=%@", name);
    } else {
        // 贴图没打进去也得有个球，否则「球没出来」和「贴图丢了」分不清
        _ball.image = nil;
        _ball.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        _ball.layer.borderWidth = 1.0;
        _ball.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
        FBLog(@"⚠️ 找不到贴图 %@，退化成纯色球", name);
    }
    [self updateShadowPath];
}

- (void)updateShadowPath
{
    // 阴影要按「圆形路径」给：默认按 bounds 算会露出四个角的方影
    _ball.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:_ball.bounds].CGPath;
}

- (void)refreshLabel
{
    _label.hidden = !_showText;
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
    [self refreshLabel];
}

@end
