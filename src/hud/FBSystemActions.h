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
BOOL FBGoBack(CGRect ballRectOnScreen);

/// 【截屏】
///
/// 两条路，**先走安全的那条**：
///   ① `ScreenshotServices`（系统自己的截图服务）：iOS 11 起截图这套能力就搬到
///      这个私有 framework 里了（SpringBoard 的 `-takeScreenshotAndEdit:` 和辅助触控的
///      「截屏」走的都是它）。**不注入任何输入**，最安全。
///   ② 取不到它的类 → 注入一次「音量加 + 电源」组合键（iOS 的截图快捷键，
///      用法号依据见 .mm 顶部）。和【全局返回】同一套注入机制、同样的三条保命写法。
///      ⚠️ 万一没被认成「组合键」，结果只是把屏幕锁上（解锁继续用），不丢东西。
///
/// - Returns: 实际走的哪条路：0 = 都没走通（日志里会写卡在哪），
///            1 = 系统截图服务，2 = 按键注入。
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

#ifdef __cplusplus
}
#endif
