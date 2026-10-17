# MEMORY.md — 悬浮球（FloatingBall）

最后更新：2026-10-16

> 硬规则看 `C:\Users\lion\.config\opencode\AGENTS.md` 与 `E:\文档\默认项目\AGENTS.md`。
> 这里只记「下次不知道就会做错」的事。

---

## 一、这是个什么项目

iPhone 上的**全局悬浮球**（类似系统「辅助触控」小白点，但可自定义）：
浮在所有 App 之上，单击/双击/滑动/长按各自绑定动作，可拖动吸边。
动作类型：打开指定 App、直达 App 内部页面（URL scheme）。

**只能走 TrollStore**（普通 App 做不到浮在别的 App 上，App Store 上那些只能借画中画取巧）。

## 二、已拍板的范围（2026-10-16 用户确认）

| 要做 | 不做（先） |
|---|---|
| 全局悬浮球、点击/双击/滑动/长按分别绑定、长按拖动吸边 | 系统开关类：WiFi / 蜂窝 / 飞行 / 蓝牙 / VPN / 降低白点值 |
| 打开指定 App、URL scheme 直达（微信扫一扫、淘宝购物车、邮件收件箱…） | 脚本 / 命令执行（**第一版不做**，见第五节） |
| 三栏 UI：启动 / 自定义快捷应用列表 / 关于 | 桌宠、GIF 背景、图标库、多语言、在线更新检查 |

## 三、参考实现 TheBall 的分析结论（2026-10-16）

- 仓库 `hhse/TheBall`（作者 mumuhmumu）**只有 IPA，没有源码**；
  已下载 `ref/TheBall2.7.ipa`（1,459,431 B）并用 Python 拆完，报告在 `ref/report.txt`、`ref/report2.txt`。
- bundle id `com.mumu.iosshare`，App 名「**后台不死是**」，Xcode 16.2 / SDK 18.2 构建，`MinimumOSVersion = 13.0`，
  单二进制 1,169,840 B，包内**没有**辅助进程/内嵌框架。
- **机制和 Helium 是同一条路**（三件套见第四节），不是别的黑魔法。
- entitlements 共 68 项，**与 `E:\文档\Helium\ent.plist` 几乎逐条相同**；
  里面还留着上家的指纹没改：`ch.xxtou.hudapp`（XTAssistiveTouch）、
  `ch.xxtou.notification.hud.dismissal`（它自己的通知却已改成 `com.mumu.*`）。
- 类名：`HUDMainApplication` / `HUDMainWindow` / `TSEventFetcher` —— **和 Helium 里同名**，同一脉。
- 它调用的私有 API（未定义符号）：`BKSHIDEventRegisterEventCallback`、`BKSDisplayServicesStart`、
  `GSInitialize`、`GSEventInitialize`、`UIApplicationInitialize`、`UIApplicationInstantiateSingleton`、
  `IOHIDEventCreateDigitizerEvent`、`SBSLaunchApplicationWithIdentifierAndLaunchOptions`、
  `SBSSpringBoardServerPort`、`SBGetScreenLockStatus`、`posix_spawn` + `posix_spawnattr_*`。

### ⚠️ 最重要的一条：**HUD 窗口能收到触摸，这是被成品证明的**

TheBall 的球是**可点可拖**的，它用的是标准手势识别器：
`UITapGestureRecognizer` / `UISwipeGestureRecognizer`（上下左右四个）/ `UILongPressGestureRecognizer` /
`UIPanGestureRecognizer`，外加 `handleCapturedPan:`、`snapToEdge`、`autoHidePosition`、
`gestureRecognizer:shouldReceiveEvent:` / `shouldReceiveTouch:` 这几个覆盖点。

→ 所以「最大未知数」（球能不能被点中）**降级为「照做」**，但仍需 v0.1 真机确认。

### 它怎么做跨进程同步 / 持久化（我们**不照抄**，太乱）

- 约 25 个 Darwin 通知名：`com.mumu.floatingball.update*`（size/opacity/color/shape/layout/…）
- 设置键名（UserDefaults）：`FloatingBallX` / `FloatingBallY` / `FloatingBallSize` / `FloatingBallOpacity` /
  `FloatingBallShapeType` / `FloatingBallHidePercentage` / `FloatingBallSwipeMode` / `FloatingBallTapCount` /
  `FloatingBallThemeColor` / `FloatingBallAppList` / `FloatingBallAutoHide` / `FloatingBallCustomImage` …
- 单实例：`/tmp/floatingball.lock` + `FloatingBallHasLaunched`
- URL scheme 自唤起：`floatingball://internal-launch-hud`
- 后台存活：`UIBackgroundModes = ['processing']` + 权限 `com.apple.security.background-task`

### 它没做、我们可以做得不一样的地方

1. **四种手势不是各自可绑定的**（它只有 `FloatingBallSwipeMode` 一个模式开关），用户要的是每个手势各绑一个动作。
2. 系统开关类：它**一个都没有**（没链 NetworkExtension / CoreTelephony / BluetoothManager）——
   和用户「这块先不做」的决定一致。
3. 它带了一堆与需求无关的东西：在线更新检查（`https://api.joia.cn/api/mumuApp/TheBall`）、GIF 桌宠、
   内置图标库、中英双语、性能监控（`PerformanceMonitor` + `task_info`）。

## 四、技术机制（三件套，两处参考实现都一致）

1. **App 用 `posix_spawn` 再启动一次自己**（argv `-hud`），属性带
   `posix_spawnattr_set_persona_np(&attr, 99, OVERRIDE)` + `set_persona_uid_np(0)` + `set_persona_gid_np(0)`
   → 这个「第二自我」以 **root** 常驻。**不需要越狱**（Helium 生产在用）。
2. 它带一整套**抄自 `assistivetouchd` 的 entitlements**（`com.apple.assistivetouch.daemon`、
   `com.apple.springboard.accessibility-window-hosting`、`com.apple.private.persona-mgmt`、
   `platform-application`、`no-sandbox` …）。清单直接用 `E:\文档\Helium\ent.plist`。
3. 它向 SpringBoard 注册一个**全局窗口**：
   `SBSAccessibilityWindowHostingController -registerWindowWithContextID:atLevel:`（Helium 用 10000010.0）。

> ⚠️ **PPL 禁项绝对不能加**（iOS 15 + A12 以上必崩）：
> `com.apple.private.cs.debugger`、`dynamic-codesigning`、`com.apple.private.skip-library-validation`。
> Helium 的 ent.plist 和 TheBall 的权限表里**都没有**这三项，别手贱加。

## 六、网络 / 推送（**看这一节能省半小时**）

### `git push` 报 `Recv failure: Connection was reset` 的根因 = **深信服 VPN**（2026-10-17 查明）

- 本机装的是**深信服 SSL VPN**（设备管理器里那张虚拟网卡叫
  `Sangfor SSL VPN CS Support System VNIC`，客户端是 EasyConnect 那一套）。
- 特征：开着它时 **`git push` / `git ls-remote` 会被重置**，
  而 **`api.github.com` 一切正常**（所以 `gh api`、REST 推送都不受影响）。
  → 「git 挂了但 gh 能用」就是这个情况，不要怀疑 token 或权限。

- ✅ **用户 2026-10-17 明确授权：遇到这个报错，直接把 VPN 关掉，不用先问。**
  关法（本机**没有**系统级 VPN 连接，`Get-VpnConnection` 是空的，别去找那个）：
  ```powershell
  # 先找到进程再退（名字随版本变，实测装的是 EasyConnect 系）
  Get-Process | Where-Object { $_.ProcessName -match 'EasyConnect|Sangfor|svpn' } | Select-Object ProcessName,Id
  Stop-Process -Name <上面查到的名字>
  ```
  注意它可能被守护进程重新拉起，必要时一起退。
- **能用 `git` 就别用 REST 脚本**：REST 每次要把 71 个 blob 重新上传一遍，慢得多。

### 首次推送是用 REST API 破的局（造成历史分叉）

见第五节表格：本地 `main` 与远端 `main` **SHA 不同**（内容一致）。
想恢复正常的 `git push`，需要对一次历史（**这属于「重置」，只给命令不代执行**）：
```powershell
git fetch origin main
git show -s --format=%T HEAD         # 与下一行的 tree 必须一致，不一致就别做
git show -s --format=%T origin/main
git reset --soft origin/main
git commit -F <消息文件>
git push
```

---

## 七、脚手架与工具链决定

- **用 Theos，不用 XcodeGen。** 沿用 `E:\文档\Helium` 的 CI 配方（工具链钉死 **Xcode 15.1 + macos-14**，
  产物是 `.tipa`），理由：要链私有框架、给二进制塞 entitlements、单 binary 按 argv 分入口。
- **可直接复用的资产**：
  - `E:\文档\Helium`：`src/hud/*`（root spawn、HUD 进程、全局窗口、HUD 事件回调）、
    `ent.plist`、`src/helpers/private_headers/*`（含 `LSApplicationWorkspace.h`、`SBSAccessibilityWindowHostingController.h`、
    `AXEventRepresentation.h`）、`src/helpers/ts/TSEventFetcher.*`、`.github/workflows/*`
- **IPA 文件名必须纯 ASCII**；版本号单一源头 + 打包时断言（照 TT 的规矩）。

### CI 实测记录（2026-10-17）

- **`macos-13` 不能用了**：排队 10 分钟起不来（Helium 在 10-15 还是秒开）。
  换 **`macos-14` 秒开**，而且该镜像自带 **Xcode 15.1**（15.0.1/15.1/15.2/15.3/15.4 都有），
  工具链一个字都不用改。
- ⚠️ **私有 framework 里的东西，一律走字符串，不走符号**（这轮唯一的编译错误就是踩了这条）：
  - 私有类：`[LSApplicationWorkspace defaultWorkspace]` → `ld: Undefined symbols: _OBJC_CLASS_$_LSApplicationWorkspace`。
    正确写法 `objc_getClass("LSApplicationWorkspace")`（Helium 也是这么写的）。
  - 私有 C 函数：`SBSLaunchApplicationWithIdentifierAndLaunchOptions` 之类用 `dlsym(RTLD_DEFAULT, "...")`
    运行时查，**别直接调用**（直接调用会把链接风险留在 SDK 的私有 stub 上）。
- ⚠️ **BOOL 返回值别用 `performSelector`**：它的返回类型是 `id`，ARC 会把 BOOL 的 `0x1` 当对象 retain → 崩。
  用 `objc_msgSend` + 显式函数指针转型。
- ⚠️ **跨 `.m` / `.mm` 的 C 函数，`.h` 里必须包 `extern "C"`**（或照 Helium 那样用 `OBJC_EXTERN`，
  它在 C++ 下就是 `extern "C"`）：
  实现放在 `.mm` 里就是 **ObjC++**，不加这层函数名会被 C++ 修饰（`_FBLog` → `__Z5FBLogP8NSStringz`），
  而 C 那边（`.m` / Swift）找的是 `_FBLog` → 链接期 `Undefined symbols: _FBLog`。
  本仓库 `FBLog.h` 已踩过一次；`HUDHelper.h` 是 `OBJC_EXTERN` 所以一直没出问题。
- 七个 Swift 文件在 Xcode 15.1 下一次过，`-swift-version` 不用调。
- 一轮 CI 约 3～4 分钟（SDK 有缓存之后），迭代成本可以接受。

### 实现上踩过的坑

- **拖动不能用 `translationInView:`**：窗口本身跟着手指移动时，手指在窗口坐标系里的位置
  会「跟着窗口一起走」，位移越算越小最后卡死（经典反馈环）。
  正确做法：每个事件都把「窗口内坐标」换算回「屏幕坐标」再定位。
  见 `src/hud/BallRootViewController.mm` 文件头注释。
- **HUD 窗口不透明的话**，球周围那圈 12pt 余量会渲染成黑块，必须
  `setOpaque:NO` + `setBackgroundColor:clearColor`。
- **HUD delegate 里的调用顺序**：`initialCenter`（它会加载共享设置）必须排在 `windowSide` 前面，
  否则球尺寸永远用默认值。
- 新仓库：**`E:\文档\悬浮球`**，远端 **`https://github.com/daofeidao/FloatingBall`**（public，GPL-3.0）。
- ⚠️ **首次推送走了 REST API**（`git push` 报 `Recv failure: Connection was reset`，就是 MEMORY 里那条 VPN 老毛病）。
  结果是**远端 main 与本地 main 分叉了**：
  | | SHA |
  |---|---|
  | 本地 `main`（原始提交） | `1191e49` |
  | 远端 `main`（API 建的同内容提交） | `21276b6` |
  远端还多一个 `init` 父提交（空仓库不能建 blob，先用 Contents API 放了个占位）。
  脚本：`ref/push_rest.py`（不走 git 传输，直接 Git Data API；含「blob sha 必须一致」和「force=false」两道闸门）。
  **想恢复 `git push`**（github.com 通了之后做）：
  ```powershell
  git fetch origin main
  git show -s --format=%T origin/main    # 与本地 HEAD 的 tree 对比，必须一致
  git show -s --format=%T HEAD
  git reset --soft origin/main
  git commit -F <消息文件>                # 内容不变，只是把父提交接上
  git push
  ```

## 八、硬规则（不要重走）

- **脚本/命令功能**：将来若要做，必须复用 TT 的 `DangerGuard`（硬拦截、无放行按钮、默认关闭）。
  悬浮球是常年浮在所有界面上的 root 入口，比 TT 更危险——
  2026-10-10 那次 `rm -rf /` 事故（`E:\文档\默认项目\MEMORY.md`）就是同源能力造成的。
- 涉及删除/覆盖/重置的操作，只给命令不代执行。
- 真机只有一台且**没有备份**，任何"要不要试"的判断都按不可逆处理。

## 九、待办 / 待验证

- [ ] **v0.1（验证版）**：球全局显示 + 能点 + 能拖 + 点一下打开「设置」。
      **这一版不通，整个形态要换**（备选：用全局 HID 回调自己算命中）。
- [ ] 顺带把 `E:\文档\默认项目\MEMORY.md` 里两条过时信息更正：
      ① 「persona root spawn 是线索未证实」→ Helium/TheBall 都在生产用；
      ② 它指向的 `E:\文档\Helium\MEMORY.md` **并不存在**。
