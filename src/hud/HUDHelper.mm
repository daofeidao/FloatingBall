#import <spawn.h>
#import <notify.h>
#import <mach-o/dyld.h>
#import <signal.h>
#import <errno.h>
#import <unistd.h>

#import "HUDHelper.h"
#import "FBLog.h"

extern "C" char **environ;

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern "C" int posix_spawnattr_set_persona_np(const posix_spawnattr_t* __restrict, uid_t, uint32_t);
extern "C" int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t* __restrict, uid_t);
extern "C" int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t* __restrict, uid_t);

NSString *FBHUDPIDFilePath(void)
{
    // ⚠️ 必须放在**两边都够得着**的地方：球是 uid 0、App 是 uid 501，
    //    各自的 NSCachesDirectory 是两个不同目录。以前用 NSCachesDirectory，
    //    所以只能靠「再 spawn 一个 -check 进程（同 persona）去读」——
    //    那正是开关迟钝 1~2 秒的根源。/tmp 两个进程都能读写（自检文件一直就在那儿）。
    return @"/tmp/FloatingBall.hud.pid";
}

BOOL IsHUDEnabled(void)
{
    // ⚠️ 2026-10-17 第五版结论（别再改回去）：**不要再 spawn 进程来问状态**。
    //    原来这里是 posix_spawn 一整个 App 二进制（persona 99 + uid 0）+ waitpid，
    //    一次 200~500ms；而开关一动会问 1~2 次 —— 用户原话「打开和关闭速度非常慢」。
    //    现在：读球进程自己写的 pid 文件 + kill(pid,0) 问内核，纯进程内，微秒级。
    NSString *pidString = [NSString stringWithContentsOfFile:FBHUDPIDFilePath()
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    if (!pidString) return NO;

    pid_t pid = (pid_t)[pidString intValue];
    if (pid <= 0) return NO;

    // kill(pid, 0) 只有三种结果：
    //   0     → 进程在，而且我们有权动它 → 在跑
    //   EPERM → 进程在，但我们没权动它（App 是 uid 501，球是 uid 0）→ 也是在跑
    //   ESRCH → 内核说没这个进程 → 没在跑（顺手删掉过期文件，免得下次又读到）
    if (kill(pid, 0) == 0) return YES;
    if (errno == EPERM) return YES;

    unlink(FBHUDPIDFilePath().UTF8String);
    return NO;
}

void SetHUDEnabled(BOOL isEnabled)
{
#ifdef NOTIFY_DISMISSAL_HUD
    notify_post(NOTIFY_DISMISSAL_HUD);
#endif

    static char *executablePath = NULL;
    uint32_t executablePathSize = 0;
    _NSGetExecutablePath(NULL, &executablePathSize);
    executablePath = (char *)calloc(1, executablePathSize);
    _NSGetExecutablePath(executablePath, &executablePathSize);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    if (isEnabled)
    {
        posix_spawnattr_setpgroup(&attr, 0);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);

        pid_t task_pid = 0;
        const char *args[] = { executablePath, "-hud", NULL };
        int rc = posix_spawn(&task_pid, executablePath, NULL, &attr, (char **)args, environ);
        posix_spawnattr_destroy(&attr);

        // ⚠️ 这个返回值是「球起不来的第一种可能」，一定要记下来
        //    EPERM(1) = persona/root 那条路被拒；ENOENT(2) = 可执行文件路径不对
        FBLog(@"spawn -hud：rc=%d pid=%d 可执行文件=%@", rc, task_pid,
              [NSString stringWithUTF8String:executablePath]);

#if DEBUG
        os_log_debug(OS_LOG_DEFAULT, "spawned %{public}s -hud pid = %{public}d", executablePath, task_pid);
#endif
    }
    else
    {
        // ⚠️ 0.1.11：这里原来先 sleep 0.25 秒、再 waitpid 等 -exit 进程结束 —— 关球要 1 秒上下。
        //    两个等待都是白等的：
        //      · sleep 0.25 —— 没有任何理由要等，-exit 自己会去读 pid 文件、杀球、删文件；
        //      · waitpid    —— -exit 干完就退，等它只让我们多卡一个进程启动的时间。
        //    现在 spawn 完就返回：开关松手即响应，真实状态由 App 侧轮询 pid 文件确认。
        pid_t task_pid = 0;
        const char *args[] = { executablePath, "-exit", NULL };
        int rc = posix_spawn(&task_pid, executablePath, NULL, &attr, (char **)args, environ);
        posix_spawnattr_destroy(&attr);
        FBLog(@"spawn -exit：rc=%d pid=%d（不等它，直接返回）", rc, task_pid);

#if DEBUG
        os_log_debug(OS_LOG_DEFAULT, "spawned %{public}s -exit pid = %{public}d", executablePath, task_pid);
#endif
    }
}

void waitForNotification(void (^onFinish)(), BOOL isEnabled) {
    if (isEnabled)
   {
       dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

       int token;
       notify_register_dispatch(NOTIFY_LAUNCHED_HUD, &token, dispatch_get_main_queue(), ^(int token) {
           notify_cancel(token);
           dispatch_semaphore_signal(semaphore);
       });

       dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
           int timedOut = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)));
           dispatch_async(dispatch_get_main_queue(), ^{
               if (timedOut)
                   os_log_error(OS_LOG_DEFAULT, "Timed out waiting for HUD to launch");
               
               onFinish();
           });
       });
   }
   else
   {
       dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
           onFinish();
       });
   }
}