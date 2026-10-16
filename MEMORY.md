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

## 五、脚手架与工具链决定

- **用 Theos，不用 XcodeGen。** 沿用 `E:\文档\Helium` 的 CI 配方（工具链钉死 **Xcode 15.1 + macos-14**，
  产物是 `.tipa`），理由：要链私有框架、给二进制塞 entitlements、单 binary 按 argv 分入口。
- **可直接复用的资产**：
  - `E:\文档\Helium`：`src/hud/*`（root spawn、HUD 进程、全局窗口、HUD 事件回调）、
    `ent.plist`、`src/helpers/private_headers/*`（含 `LSApplicationWorkspace.h`、`SBSAccessibilityWindowHostingController.h`、
    `AXEventRepresentation.h`）、`src/helpers/ts/TSEventFetcher.*`、`.github/workflows/*`
- **IPA 文件名必须纯 ASCII**；版本号单一源头 + 打包时断言（照 TT 的规矩）。
- 新仓库位置/名字：**E:\文档\悬浮球**（已建），远端待定。

## 六、硬规则（不要重走）

- **脚本/命令功能**：将来若要做，必须复用 TT 的 `DangerGuard`（硬拦截、无放行按钮、默认关闭）。
  悬浮球是常年浮在所有界面上的 root 入口，比 TT 更危险——
  2026-10-10 那次 `rm -rf /` 事故（`E:\文档\默认项目\MEMORY.md`）就是同源能力造成的。
- 涉及删除/覆盖/重置的操作，只给命令不代执行。
- 真机只有一台且**没有备份**，任何"要不要试"的判断都按不可逆处理。

## 七、待办 / 待验证

- [ ] **v0.1（验证版）**：球全局显示 + 能点 + 能拖 + 点一下打开「设置」。
      **这一版不通，整个形态要换**（备选：用全局 HID 回调自己算命中）。
- [ ] 顺带把 `E:\文档\默认项目\MEMORY.md` 里两条过时信息更正：
      ① 「persona root spawn 是线索未证实」→ Helium/TheBall 都在生产用；
      ② 它指向的 `E:\文档\Helium\MEMORY.md` **并不存在**。
