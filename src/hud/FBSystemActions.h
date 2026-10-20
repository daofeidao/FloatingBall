//
//  FBSystemActions.h
//
//  「系统级动作」：不在我们进程里、得借系统私有能力才干得成的事。
//  全部走 dlsym + 字符串取符号（**不直接链接私有符号**），和 HUD 那边一个规矩。
//
//  HUD 进程（root）和 App 进程（uid 501）都会调这里 ——
//  同一个二进制、同一份 entitlements，只是 uid 不同。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 刷新蜂窝网络信号（卡贴机没信号 / 假信号时点一下用）。
///
/// 机制来自 TrollSIMSwitcher（Apache-2.0）：让基带重新注册、重新搜网。
/// ⚠️ **这个 API 没有结果**：它只是把请求丢给 CommCenter 就返回了，
///     成没成只能看状态栏的信号格有没有回来。
///     所以这里返回的是「请求有没有发出去」，不是「信号有没有回来」。
/// ⚠️ 需要 entitlement：com.apple.CommCenter.fine-grained = [ "spi" ]（见 ent.plist）。
///     没有这个权限，CommCenter 会直接把请求丢掉，连报错都没有。
BOOL FBRefreshCellularSignal(void);

/// 打开任意 App。
/// 两条路：LSApplicationWorkspace（优先）→ SBSLaunchApplicationWithIdentifierAndLaunchOptions（兜底）。
/// 全部字符串查找，取不到只是返回 NO，不会链接失败。
BOOL FBOpenApplication(NSString *bundleID);

/// 打开任意 URL —— 「URL 协议」类快捷项都走这里（微信扫一扫 `weixin://scanqrcode`、
/// 微信收付款 `weixin://widget/pay`、支付宝扫一扫 `alipayqr://platformapi/startapp?saId=10000007`），
/// 「系统快捷指令」也走这里（`shortcuts://run-shortcut?name=<名字>`，Apple 官方 scheme）。
///
/// 三条路按可靠性排，全部字符串查找/objc_msgSend，取不到只是往下退：
///   ① LSApplicationWorkspace `-openURL:withOptions:error:`（root 进程里的正路）
///   ② 同一个 workspace 的 `-openSensitiveURL:withOptions:`（有些 scheme 只认这条口子）
///   ③ UIApplication `-openURL:options:completionHandler:`（App 进程里的正路）
///
/// ⚠️ 返回 YES 只代表**系统收下了这个请求**，不代表对面真的执行了 ——
///    比如系统快捷指令的名字写错，是「快捷指令」App 自己弹「找不到」。
BOOL FBOpenURL(NSString *urlString);

/// 【全局返回】往系统里**注入一次「从左缘往右划」的触摸**，效果等于用户按了「上一页」。
///
/// ⚠️⚠ 这是全项目**最危险**的一个动作 —— 唯一一个能伤到系统本身的：
///   注入的是一串真实触摸事件（按下 → 移动 → 抬起）。要是「抬起」没送出去，
///   屏幕上就会卡住一个「一直按着不放的手指」：那个位置点不动、拖不动，
///   只能强制重启。球自己那块最坏只是「球不灵」，绝不会卡住系统触摸。
///   所以实现里是「**先把整串事件全造出来，造不全就一个都不发**」，见 .mm 顶部。
///
/// - Parameter ballRectOnScreen: 球在屏幕上的矩形（最好带一点宽容区）。
///   落点会避开它 —— 不然球会把自己注入的划动当成「用户在拖它」（球乱跑，甚至自己触发自己）。
/// - Returns: 有没有真的注进去。
///   取不到 HID 符号 / 还没学到真机 sender ID / 0.6 秒内刚划过一次 → 返回 NO，**什么都没做**。
///
/// ⚠️ 0.1.39：这串事件必须带 `kIOHIDDigitizerEventFromEdgeTip`（1 << 11）——
///    没有这一位，UIKit 不把这个触点当成「从屏幕边缘起手」，
///    `UIScreenEdgePanGestureRecognizer` 就不会认，划出去只会变成普通横向滑动。
///    这是**官方事件掩码位**，不是按字节偏移写内存（原因见 .mm 里那段长注释）。
BOOL FBGoBack(CGRect ballRectOnScreen);

/// 【打开邮箱收件箱】（0.1.36，用户要求）
///
/// 场景很具体：Mail 上次停在**那封带 tipa 附件的邮件详情页**，点球之后要退回收件箱列表。
/// 光划一次左缘返回**划不动** —— 那个页面在某些状态下识别器压根不认边缘返回，
/// 所以用户实测出来的办法是「**先点一下上方 1/3 的空白**，再划」。
///
/// 这个函数把整条链路串起来（异步，立刻返回）：
///   ① `FBOpenApplication(com.apple.mobilemail)` 把 Mail 拉到前台（在跑就切前台，上次那页还在）；
///   ② 1.6 秒后注入一次「点一下」（屏幕 x 中点、y 30% 处）；
///   ③ 再 0.4 秒后调 `FBGoBack(ballRectOnScreen)` 完成返回。
///
/// - Parameter ballRectOnScreen: 球的屏幕矩形，给最后那一下返回用（落点避开球）。
/// - Returns: 有没有把 Mail 拉起来。NO = 后面两步都不会发生。
///   （点一下那步如果因为「还没学到 sender ID」失败，日志里会写原因，不影响本函数返回值。）
BOOL FBOpenMailInbox(CGRect ballRectOnScreen);

/// 【截屏】
///
/// 两条路，**先走安全的那条**：
///   ① `AXSpringBoardServer`（AccessibilityUtilities）的 `-takeScreenshot`：
///      **让 SpringBoard 自己截**，辅助触控的「截屏」用的就是这条 XPC。
///      不注入输入、也不在本进程里做截图 → 不会卡键、也不会把 HUD 弄崩。
///   ② 取不到它 → 注入一次「音量加 + 电源」组合键（iOS 的截图快捷键，
///      用法号依据见 .mm 顶部）。和【全局返回】同一套注入机制、同样的三条保命写法。
///      ⚠️ 万一没被认成「组合键」，结果只是把屏幕锁上（解锁继续用），不丢东西。
///
/// - Returns: 1 = 已发起（AX 优先，失败会在后台自动退到按键注入）；
///            0 = 这次没发起（上一次请求还没回来）。
///
/// ⚠️ 0.1.33：删掉了 0.1.32 的 `ScreenshotServices` 那条 —— 用户实测「点截屏球就没了」，
///    那是 SpringBoard 内部的类，在别的进程里实例化会崩。别再拿回来。
int FBTakeScreenshot(void);

/// 从一条真实的 HID 事件里记下 sender ID。
/// 注入触摸时必须用**真机那一路**的 sender ID（配方来源里的工具为这个专门先监听一次真触摸，
/// 取不到就拒绝注入）。HUD 的 `_HUDEventCallback` 每条事件调一次就够，内部自己判断类型。
/// ⚠️ 参数写成 void * 是为了让 Swift 桥接头不用认识 IOHIDEventRef。
/// ⚠️ **这个函数里不做任何加载**（不 dlopen）：它跑在 backboardd 的事件线程上，
///    在那儿做加载有把 HID 回调卡死的风险（2026-10-17 的教训）。预热走 `FBPrepareHID()`。
void FBHIDNoteRealEvent(void *hidEvent);

/// 预热 HID 这一套（dlopen + dlsym + 建 client）。
/// ⚠️ **HUD 启动时先调一次**，别等到回调里才加载（见上一条的说明）。
/// 注入（全局返回）在动手前也会再调一次（那时在 HUD 主线程上，安全）。
void FBPrepareHID(void);

/// 这条 HID 事件的类型号（触摸 = `kIOHIDEventTypeDigitizer` = 11；0 = 拿不到）。
/// 给 HUD 的「触摸自检」用：能把「压根没收到触摸事件」和「收到了但没认出来」分开。
int FBHIDEventTypeOf(void *hidEvent);

// ---- 触摸自检：直接读底层数字字段（0.1.11）----
// ⚠️ 为什么不看 AXEventRepresentation 的 isTouchDown：真机自检（0.1.10 之前）
//    3 万条事件里它一次都没为真，「等按下」就等于永远等不到。
//    这三个函数问的是 IOHID 事件自己的字段，注入工具（ZXTouch）用的就是这套：
//      按下 = Range 1 + Touch 1；移动 = Touch 1；抬起 = Touch 0。
// - Returns: 1 = 是，0 = 否，-1 = 取不到（不是触摸事件 / 符号没拿到）。

int FBHIDDigitizerTouchOf(void *hidEvent);
int FBHIDDigitizerRangeOf(void *hidEvent);
int FBHIDDigitizerMaskOf(void *hidEvent);

/// 0.1.14：**会翻子事件**的读法（上面三个只在「事件自己」身上读，父事件上永远是 0）。
/// 真机事件的 X/Y/Touch/Range 都在 digitizer 的子事件上，见 FBSystemActions.mm 里的长注释。
/// - touch: 1 = 在屏，0 = 离屏，-1 = 取不到
/// - range: 1 = 刚进入感应，0 = 离开，-1 = 取不到
/// - nx / ny: 归一化 0~1 的手指坐标（乘屏幕尺寸就是点；没有就是 0）
/// - Returns: 1 = 读到了（touch/range 有意义），0 = 这条事件上没有手指信息
int FBHIDReadTouchDeep(void *hidEvent, int *touch, int *range, double *nx, double *ny);


#ifdef __cplusplus
}
#endif
