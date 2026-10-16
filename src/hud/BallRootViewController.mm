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

#import <notify.h>

#import "../helpers/private_headers/LSApplicationWorkspace.h"

// 默认值
static const CGFloat kDefaultBallSize = 56.0;
static const CGFloat kWindowPadding = 12.0;   // 窗口比球大一圈：给阴影和手指宽容区

static void LightHaptic(void)
{
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [g prepare];
    [g impactOccurred];
}

@implementation BallRootViewController {
    UIView *_ball;
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

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self loadPrefs];
    _showText = YES;

    self.view.backgroundColor = [UIColor clearColor];

    CGFloat side = [self windowSide];
    CGFloat ball = [self ballSize];

    _ball = [[UIView alloc] initWithFrame:CGRectMake((side - ball) / 2.0, (side - ball) / 2.0, ball, ball)];
    _ball.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    _ball.layer.cornerRadius = ball / 2.0;
    _ball.layer.borderWidth = 1.0;
    _ball.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    _ball.layer.shadowColor = [UIColor blackColor].CGColor;
    _ball.layer.shadowOpacity = 0.35;
    _ball.layer.shadowRadius = 6.0;
    _ball.layer.shadowOffset = CGSizeMake(0.0, 2.0);
    _ball.userInteractionEnabled = YES;
    [self.view addSubview:_ball];

    _label = [[UILabel alloc] initWithFrame:_ball.bounds];
    _label.textAlignment = NSTextAlignmentCenter;
    _label.textColor = [UIColor whiteColor];
    _label.font = [UIFont systemFontOfSize:MAX(11.0, ball * 0.32) weight:UIFontWeightSemibold];
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
        [self reloadSettings];
    });
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
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

    LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
    [ws openApplicationWithBundleID:@"com.apple.Preferences"];
}

- (void)onDoubleTap:(UITapGestureRecognizer *)g
{
    // v0.1：双击先把计数清零（v0.2 起改成「用户自己绑定的动作」）
    _prefs[@"TapCount"] = @0;
    [self savePrefs];
    [self refreshLabel];
    LightHaptic();
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
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
}

#pragma mark - 视图刷新

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
}

- (void)reloadSettings
{
    [self loadPrefs];
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
