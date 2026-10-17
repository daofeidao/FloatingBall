//
//  FBLog.h
//
//  为什么需要它：悬浮球跑在一个**独立的 root 进程**里，球不出来的时候
//  手机上根本看不到 Console 日志（没有 Xcode、没有 Mac）。
//  所以统一往 /tmp/FloatingBall.log 落一份文本，用手机上的终端就能 cat。
//
//  /tmp 在 iOS 上是 /private/var/tmp 的软链，全世界可写，
//  app（uid 501）和 HUD（root）都能写，也能被终端 App 读到。
//

#import <Foundation/Foundation.h>

#define FB_LOG_PATH @"/tmp/FloatingBall.log"

// ⚠️ 必须包 extern "C"：
//    实现放在 FBLog.mm 里，那是 **ObjC++**，不加这层的话函数名会被 C++ 修饰成
//    __Z5FBLogP8NSStringz，而 C 那边（SwiftObjCPPBridger.m）找的是 _FBLog，
//    链接期直接 undefined symbols。
//    （Helium 的 HUDHelper.h 用 OBJC_EXTERN，在 C++ 下展开就是 extern "C"，同一个道理。）
#ifdef __cplusplus
extern "C" {
#endif

/// 追加一行日志：时间 + pid + 内容。失败就静默忽略，绝不因为日志而崩。
void FBLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// 清空日志（每次「开球」时调用，避免越滚越大）
void FBLogReset(void);

#ifdef __cplusplus
}
#endif
