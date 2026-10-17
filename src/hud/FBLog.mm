#import "FBLog.h"

#import <stdio.h>
#import <unistd.h>
#import <stdarg.h>
#import <time.h>

/// ⚠️ 这里刻意用最土的办法（fopen/fputs + localtime_r）：
///    1. 日志函数必须**绝对不可能崩**，一切失败静默吞掉；
///    2. 不用 NSDateFormatter —— 它非线程安全，HUD 里有多个线程会记日志；
///    3. 不用 @try —— 万一工具链关了 objc 异常，@try 会直接编不过。
void FBLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    time_t now = time(NULL);
    struct tm parts;
    localtime_r(&now, &parts);

    NSString *line = [NSString stringWithFormat:@"%02d:%02d:%02d [%d] %@\n",
                      parts.tm_hour, parts.tm_min, parts.tm_sec, getpid(), message];

    FILE *fp = fopen("/tmp/FloatingBall.log", "a");
    if (fp) {
        const char *utf8 = [line UTF8String];
        if (utf8) fputs(utf8, fp);
        fclose(fp);
    }

    NSLog(@"[FloatingBall] %@", message);
}

void FBLogReset(void)
{
    FILE *fp = fopen("/tmp/FloatingBall.log", "w");
    if (fp) {
        fputs("=== FloatingBall 日志开始 ===\n", fp);
        fclose(fp);
    }
}
