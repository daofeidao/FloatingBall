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

/// 追加一行日志：时间 + pid + 内容。失败就静默忽略，绝不因为日志而崩。
void FBLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// 清空日志（每次 App 启动时调用，避免越滚越大）
void FBLogReset(void);
