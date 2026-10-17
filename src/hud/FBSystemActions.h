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

#ifdef __cplusplus
}
#endif
