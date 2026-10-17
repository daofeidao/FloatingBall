# MEMORY.md — 悬浮球（FloatingBall）

最后更新：2026-10-17

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
| 三栏 UI：启动 / 自定义快捷应用列表 / 关于 | 桌宠、GIF 背景、多语言、在线更新检查 |
| 球的外观可调：形状（内置 3 个 + 自定义图片）/ 颜色 / 大小 / 不透明度（2026-10-17 用户新增） | 完整「图标库」（只做内置那几个，见第七节） |
| 快捷列表（打开 App + 内置动作）、单击/双击/长按各绑一个动作、一键刷新信号（2026-10-17 追加） | 系统开关类里的飞行模式开关（`RadiosPreferences` 那套，单独一轮再说） |
| | 「系统级返回」「截图」：要靠 HID 注入，见第十节 |

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

### ⚠️ 触摸这一条：当年判断错了，2026-10-17 真机改正

这里的原文是「HUD 窗口能收到触摸，这是被成品证明的」—— **这个推论是错的**，
0.1.0~0.1.2 就是被它带偏的。TheBall 的球确实可点可拖，用的是标准手势识别器
（`UITapGestureRecognizer` / `UISwipeGestureRecognizer` / `UILongPressGestureRecognizer` /
`UIPanGestureRecognizer`，外加 `handleCapturedPan:`、`snapToEdge`、`autoHidePosition`、
`gestureRecognizer:shouldReceiveEvent:` 这几个覆盖点），

**但它能点 ≠ 窗口能收触摸。** 真机结果是：SpringBoard 托管的窗口**只负责显示**，
触摸一个都送不进来。回头再看 TheBall 的私有 API 清单，
里面**有 `BKSHIDEventRegisterEventCallback`** —— 它八成是靠那条路自己喂触摸的，
只是当时我们只盯着「它有手势识别器」这一半。

→ 结论：手势识别器照抄没问题（那是「收到触摸之后」的事），
但「触摸怎么进来」必须自己解决，见第十一节。

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
   ⚠️ 这一步只解决**显示**。
4. **触摸要单独想办法**（2026-10-17 真机推翻「窗口能收触摸」的假设）：
   那个窗口收到的是 0 个触摸事件（`_ignoresHitTest` 改 NO 也没用）。
   现在用「全局 HID 事件回调 + 自己喂 UITouch」，见第十一节。

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

### 球的样子 = App 画好一张贴图（2026-10-17，已改版）

用户原话的大意：「桌面图标做成跟手机自带的小白点一样；启动页里能自己设计球的大小，要能缩放；
已经画好的图就保留着让客户自己选，默认出两三张放软件里当备选。」
后来又补：那一栏准确说是「**设置这个图标的界面**」，并且要能调**透明度 / 颜色 / 自定义图片**。

**现在的架构（v0.1.0 之后的这一版）**：

```
App 侧（uid 501）                          HUD 侧（root）
┌──────────────────────────────┐          ┌────────────────────────────┐
│ BallRenderer.swift           │  写文件  │ BallRootViewController.mm  │
│  按 形状+颜色+自定义图 画 PNG  │ ───────> │  imageWithContentsOfFile:  │
│  -> Preferences/....ball.png │          │  + alpha = BallOpacity     │
└──────────────────────────────┘          └────────────────────────────┘
        ↑ 预览用的也是这个函数                    ↑ 找不到文件就退回包里的 BallDot.png
```

- ⚠️ **为什么不在 HUD 里画**：画图只留**一份代码**（Swift），
  App 里的预览和屏幕上的球走同一个函数，杜绝「预览和实际不一样」。
- ⚠️ **代价**：`BallRenderer.swift` 的比例参数（0.57 / 0.075 / 0.035 …）必须和
  `scripts/make_icon.py` 的 `STYLES` 保持一致，改比例要**两边一起改**。
  桌面图标固定 = 「小圆点」那一套。
- **设置键**：`BallShape`（`dot`/`plain`/`white`/`custom`）、`BallColor`（`#RRGGBB`）、
  `BallSize`（32~100）、`BallOpacity`（0.3~1.0）。**不再有 `BallStyle` 这个贴图名键**。
- **环 / 十字用对比色**（body 亮度 > 0.6 → 画黑，否则画白），所以颜色随便选都看得见。
  `white` 是预设（不透明白身 + 深色环），`custom` 用相册的图裁成圆。
- **重画时机**：只有「形状 / 颜色 / 自定义图」重画；
  「大小 / 不透明度」不重画（贴图比例是相对直径的，HUD 拉伸 + 设 alpha 即可），
  否则拖滑块每动一下都要编码一次 PNG，界面会卡。
- 打包进 App 的 3 张 PNG 现在是**设置界面的缩略图** + `BallDot.png` 兼兜底贴图。
- ⚠️ **`ipabuild.sh` 原来只拷 `Info.plist` + AppIcon**（从 `.theos/obj/.../FloatingBall.app` 打包，
  不是从 `layout/`）→ 新增的贴图**不会自动进包**。
  已改成拷 `layout/.../*.png` 全部，并加了一道硬闸：「三张球贴图必须在 Payload 里」。
  少一张不会编译报错，只会在手机上表现为「换样式没反应」。
- ⚠️ **相册选图用 `PHPickerViewController`**（`src/views/CustomImagePicker.swift`）：
  iOS 15 上没有 SwiftUI 的 `PhotosPicker`（要 16+）；PHPicker 的好处是**不需要相册权限**
  （系统在另一个进程里把图拷给我们），不弹权限框。Info.plist 里那条 `NSPhotoLibraryUsageDescription`
  只是保险。
- 大小：滑块 32~100pt；HUD 侧 `ballSize` 里硬限 24~160（防手改 plist 搞出个巨型球）。
  透明度 HUD 侧硬限 0.3~1.0 同理。
- ⚠️ 贴图 PNG 放在 `Preferences/` 目录下**是有意的**：cfprefsd 只管 `.plist`，不管 `.png`，
  放这儿不会被它搅和。

### 快捷列表 / 手势绑定 / 一键刷新信号（2026-10-17 追加，0.1.2）

用户原话：快捷程序里要一个「一键刷新信号」；单击/双击/拖动这些手势的备选里
要有【系统级返回】【截图】【打开主程序界面】【移动悬浮图标】【打开快捷应用列表】等。

**数据模型（App 和 HUD 读同一份 plist）**：

| 键 | 内容 |
|---|---|
| `Shortcuts` | 数组 `[{kind: "app"\|"action", id, title}]` |
| `GestureTap` / `GestureDoubleTap` / `GestureLongPress` | 一条字符串：`app:<bundleID>` 或 `action:<动作名>` |
| `ShowLabel` | 球上的数字显不显示（原来是内存态，现在持久化） |
| `HapticsEnabled` | 震动反馈开关（Bool，**默认开**；「没设过」必须当开，见下「震动反馈」） |
| `PendingTab` | HUD 写、App 读一次就清：`"apps"` / `"launch"` |

- ⚠️ **手势绑定存 key，不存下标**（`app:xxx` / `action:xxx`）。
  存下标的话，快捷列表一排序/删除，绑定就全错位了。
- ⚠️ **Swift 里别用元组数组 + `ForEach(id: \.key)`**：keyPath 不能指向元组成员，编译不过。
  用 `ShortcutStore.GestureSlot` 结构体。
- ⚠️ **Picker 里不能出现重复 tag**：`ShortcutItem.make(action:)` 的 key 是 `action:refreshSignal`，
  和内置动作那一组的 tag 一模一样 → 同一份菜单里两个相同 tag，Picker 分不清选中谁。
  所以手势菜单里**只列 `kind == .app` 的快捷项**。
- 「打开悬浮球 / 打开快捷列表」走 **写 `PendingTab` + 拉起 App**，**不用 URL scheme**：
  不用动 Info.plist，而且 App 没在跑时也生效（启动时读一次；
  在后台跑着时靠 `didBecomeActive` 再读一次，两条路都覆盖）。App 读完立刻清空，免得下次白跳。

**内置动作**（`ShortcutAction`）与实现位置：

| 动作 | 实现 |
|---|---|
| `refreshSignal` | `FBRefreshCellularSignal()`（私有 API，见下） |
| `openMainApp` / `openAppList` | `PendingTab` + `FBOpenApplication(OWN_BUNDLE_ID)` |
| `moveBall` | HUD 侧移动模式：球加蓝圈高亮、隐藏数字、点一下退出、拖完自动退出（防误触） |
| `toggleLabel` | 写 `ShowLabel` + `savePrefs`，HUD 和 App 都能改（`reloadSettings` 会重读） |
| `none` | 不做事 |

- 新文件 `src/hud/FBSystemActions.{h,mm}`：`FBRefreshCellularSignal` / `FBOpenApplication`
  两个 C 函数，**HUD 和 App 共用一份实现**（同一个二进制、同一份 entitlements，只是 uid 不同）。
  `BallRootViewController` 的 `openApplication:` 现在只是转调。
- 三个手势改成执行绑定动作；**轻点仍然照旧计数 +1**（球浮在别人上面时，这是唯一看得见的「点到了」回执）。

**刷新信号（卡贴机）的机制**：

```
_CTServerConnectionCreate(kCFAllocatorDefault, NULL, NULL)
_CTServerConnectionResetModem(conn, CFSTR("UserTriggeredReload"))
```

- 做法来源 `DevelopCubeLab/TrollSIMSwitcher`（**Apache-2.0**，可照做，署名即可）。
  关键文件 `Controller/CoreTelephonyController.swift`、`Controller/CellularController.swift`、
  `Controller/AppCapability.swift`。
- ⚠️ **必须加 entitlement `com.apple.CommCenter.fine-grained = [ "spi" ]`**（已加进 `ent.plist`）：
  没有它，CommCenter **直接把请求丢掉**，连报错都没有。
- ⚠️ **这个 API 没有结果**：请求发出去函数就返回了，成没成只能看状态栏信号格。
  所以日志里只写「已请求重置基带」，**不写成功/失败** —— 这是 API 本身决定的，不是我们没写。
- ⚠️ 它只是让基带重载重新搜网，**不碰卡贴、不碰 IPCC、不改锁频**。
  卡贴机真掉信号时通常还要配合：拨 `*` 取激活信号 / 重刷 IPCC / 切卡槽。
- dlsym 取符号，`Makefile` 只是把公开的 `CoreTelephony` 链上（拿句柄用），私有符号仍然不链接。

**震动反馈（0.1.4，用户 2026-10-17 追加）**：

- 键 `HapticsEnabled`（Bool，**默认开**）。
  ⚠️ **「没设过」必须当「开」**：Swift 侧 `BallSettings.bool(..., default: true)`，
  HUD 侧判断 `_prefs[@"HapticsEnabled"]` 是不是 `NSNumber` 且为 false —— 升级上来的用户没这个键，
  按 false 处理就会突然静音。
- **两份实现**（两个进程，代码没法共用）：HUD 侧 `BallRootViewController.mm`
  的 `FBHapticPlay()` + `- haptic:`；App 侧 `src/controllers/Haptics.swift` 的 `Haptics.fire()`。
  改键名/默认值/震感要**两边一起改**。
- 三档：`tap`（轻）= 识别到点击 / 球落位 / 选中选项；`action`（中）= 动作真的执行了
  （移动模式、数字开关、开关悬浮球、复位位置）；`notice`（通知两下）= 刷新信号 ——
  ⚠️ 只表示「交代出去了」，**不表示成功**（那个 API 没有回执，用 success 手感别解读成成功）。
- 开关放 App 首页「启动」栏，旁边配一个「试一下震动」按钮（**走同一个开关**：
  关着就不震 —— 如果它无视开关硬震，用户会以为开关坏了）。
  打开开关那一下硬震一次（`force: true`）：要让用户立刻感觉到「开了」。
- ⚠️ 手机上「设置 → 声音与触感 → 系统触感反馈」关掉的话全部没感觉。
  那是系统总开关，绕不过去 → App 界面 footer 和交付邮件里都要提示用户去查这一条。

## 八、硬规则（不要重走）

- **脚本/命令功能**：将来若要做，必须复用 TT 的 `DangerGuard`（硬拦截、无放行按钮、默认关闭）。
  悬浮球是常年浮在所有界面上的 root 入口，比 TT 更危险——
  2026-10-10 那次 `rm -rf /` 事故（`E:\文档\默认项目\MEMORY.md`）就是同源能力造成的。
- 涉及删除/覆盖/重置的操作，只给命令不代执行。
- 真机只有一台且**没有备份**，任何"要不要试"的判断都按不可逆处理。

## 九、待办 / 待验证

- [x] 球**全局显示**：2026-10-17 真机确认**正常**（每个界面都在，切 App、回桌面都在）。
- [ ] 球**能点 / 能拖**：0.1.0~0.1.2 一直不通，原因是窗口收不到触摸（见第十一节）。
      0.1.3 改走「全局 HID 事件回调」这条路，**仍没通**：
      2026-10-17 用户反馈「点球**直接穿透**了，没点到球的面板，球下面的屏幕（也收到了）」——
      即**球一个触摸都没接管**（数字不涨、动作不触发）。
      0.1.6 加的「触摸自检」（见第十一节末）已经**给出结论**：`回调=0`、按音量键也不涨
      → 老那条 `BKSHIDEventRegisterEventCallback` 在 15.6.1 上**一条事件都收不到**。
      0.1.7 换了另一条路（`IOHIDEventSystemClient` 监视客户端，见第十一节末），**待真机验证**。
- [ ] **0.1.7 待验（本轮最想要的两条数）**：
      ① 「关于」页 `匹配服务=` 是几（正常 1；**0 = 新路连触摸屏都没匹配上**）；
      ② 点球之后 `路A=` / `路B=` 涨不涨、`最后：` 写什么。
      三种走向：`匹配服务=0` → 匹配写法错；`=1` 但 `路B=0` → 权限/投递问题；
      `路B` 涨而 `接管=0` → 看 `最后：` 的坐标与球矩形（坐标口径）。
      因为 0.1.6 的 `回调=0`（按音量键也不涨）已经证明**路A 在 15.6.1 上收不到任何事件**。见 §十一 末。
- [ ] **0.1.7 震动待验**：按「试一下震动」应该是**手指按下去**就震（不是松开），
      「复位位置」「刷新」「换一张图片」同理；球的震感是否比 0.1.6 利索。
- [ ] **已知副作用待观察**：HID 回调不能吃掉事件 → 点在球上时球下面的 App 也会收到这一下。
      实机上体验到底有多烦（球吸在屏幕边上、下面多为壁纸/列表边缘），等用户反馈再决定要不要治。
- [ ] 真机上顺带验外观：三种样式能否即时切换（不重启）、大小滑块是否即时生效、桌面图标是不是小圆点。
- [ ] **0.1.4 震动反馈待验**：点球 / 球落位 / 执行动作各震一次；
      「启动」页开关能关掉（关了连「试一下震动」按钮也不震）。
      ⚠️ 如果整机都不震，先查「设置 → 声音与触感 → 系统触感反馈」是不是关的，别先怀疑代码。
- [ ] **0.1.5 全局返回待验**：把某条手势绑成「全局返回」→ 在「设置」的二级页面点球 →
      页面应该退回去。顺带看日志这几行的顺序（`/tmp/FloatingBall.log`）：
      `全局返回：HID 注入这条路通了` → `HID：学到真机 sender ID = 0x…` →
      `全局返回：开始注入（…落点 x=2→235 y=…）` → `全局返回：注入完了`。
      · 日志说「还没学到真机 sender ID」= 真触摸的 sender ID 没抓到（摸一下屏幕再来）。
      · 日志说「符号取不全」= IOKit 那几个私有符号在这台机器上取不到，这条路走不通。
      · 注入完了但界面没退 = 坐标/配方不对（无危险），下一轮调。
      ⚠️ 这是**唯一一个能伤到系统的动作**：万一界面卡住点不动 → 长按电源+音量减强制重启。
      头几次用请盯着点，别在编辑到一半、有未保存内容的地方试。
- [ ] 顺带把 `E:\文档\默认项目\MEMORY.md` 里两条过时信息更正：
      ① 「persona root spawn 是线索未证实」→ Helium/TheBall 都在生产用；
      ② 它指向的 `E:\文档\Helium\MEMORY.md` **并不存在**。

### 交付记录

> **固定规矩见全局 `AGENTS.md` 第八节：出包后 IPA 本体必须以附件发进用户邮箱。**
> 用户只能在手机上下载附件 → 交给巨魔安装；只在聊天里说一声、只给本地路径、
> 只给 GitHub 链接，都等于没交付。主题固定带版本号 +「含 IPA」。
> 正文必须带：文件名 + 字节数 + **sha256** + 怎么装/怎么用/怎么验 + 已知问题。
> 邮件发失败要当场在聊天里说清楚原因，不能默默吞掉。
> 核验用 `C:\Users\lion\.workbuddy\skills\mail-126\scripts\read_mail.py`（126 的 IMAP 必须先发 `ID` 命令）。

| 版本 | 时间 | 交付文件 | 字节数 | sha256 前 8 位 |
|---|---|---|---|---|
| 0.1.0 | 2026-10-16 | `E:\下载\FloatingBall_0.1.0.tipa` | 151,343 | `fffe2cb6` |
| 0.1.2 | 2026-10-17 | `E:\下载\FloatingBall_0.1.2.tipa` | 293,376 | `73ad077f` |
| 0.1.3 | 2026-10-17 | `E:\下载\FloatingBall_0.1.3.tipa` | 299,643 | `f0e1e092` |
| 0.1.4 | 2026-10-17 | `E:\下载\FloatingBall_0.1.4.tipa` | 303,232 | `056a29c9` |
| 0.1.5 | 2026-10-17 | `E:\下载\FloatingBall_0.1.5.tipa` | 309,304 | `6711a8d2` |
| 0.1.6 | 2026-10-17 | `E:\下载\FloatingBall_0.1.6.tipa` | 316,121 | `feb59a51` |
| 0.1.7 | 2026-10-17 | `E:\下载\FloatingBall_0.1.7.tipa` | 326,684 | `4d8303bf` |

- 0.1.7：tag `v0.1.7` → CI run `39034218323` **success** → 交付邮件 **20:56 发出**
  （附件已在 126 收件箱核验：`FloatingBall_0.1.7.tipa` 319.0 KB = 326,684 字节，
  sha256 `4d8303bf797ae00f37e288096859fa7de3d676de99c0bf296dc87708d673d73e`，
  包内 0.1.7 / build 8，二进制 **929,088 B** —— 比 0.1.6 大 53,952 B）。
  内容是**触摸换路（IOHIDEventSystemClient 监视客户端，两条路一起听）+ 震动跟手性**
  （见 §十一 末、「震动」那节）。正文落盘 `ref/mail_0.1.7_body.txt`。
  远端 main 推到 `c2668821a1681e1f63bf59ba197224a776f5847e`（本地提交 `e93a590`）。

  核对脚本落盘 **`ref/fetch_release.py`**（走 API 取 Release 附件 → 落 `E:\下载\` →
  验 sha256 / 包内版本 / 二进制大小 / 新字符串在不在，并跟上一版对照）。
  0.1.7 的核对结果：`IOHIDEventSystemClientCreateWithType` /
  `…RegisterEventCallback` / `…ScheduleWithRunLoop` / `PrimaryUsagePage`（都是 UTF-8）、
  「监视客户端」「路A」「路B」「匹配服务」（`__ustring`，UTF-16-LE + 也撞见 UTF-8 副本）
  在 0.1.7 有、在 0.1.6 全无；Swift 侧 `HapticOnPressModifier`、ObjC 侧 `warmHaptics` 同理。

- 0.1.6：tag `v0.1.6` → CI run `39022401985` **success** → 交付邮件 **17:51 发出**
  （附件已在 126 收件箱核验：`FloatingBall_0.1.6.tipa` 308.7 KB ≈ 316,121 字节，
  sha256 `feb59a51adfcf6077a9e7419867d1171d505e8b66f700d803784d618eaa90f9f`，
  包内 0.1.6 / build 7，二进制 875,136 B —— 比 0.1.5 大 33,776 B）。
  内容是**触摸自检 + 触摸链路上两处修正**（见 §十一 末）。正文落盘 `ref/mail_0.1.6_body.txt`。
  远端 main 推到 `6c04e8f2a9b30179a58709b68c3eba78a6cbedea`（本地提交 `98743c6`）。

  ⚠️ **核对包里有没有这版改动的新姿势**：`.mm` 里的中文 `@"…"` 字面量在二进制里是
  **UTF-16-LE**（`__ustring`），拿 UTF-8 字节去 `in` 是找不到的（会误判成「改动没进包」）；
  Swift 里的中文字面量才是 UTF-8。0.1.6 就是这么核对的：同一批串在 0.1.5 里
  UTF-16-LE 找不到、在 0.1.6 里都在 → 改动确实进包了。

- 0.1.5：tag `v0.1.5` → CI run `39015911490` **success** → 交付邮件 16:12 发出
  （附件已在 126 收件箱核验：`FloatingBall_0.1.5.tipa` 302.1 KB ≈ 309,304 字节，
  sha256 `6711a8d2b2155da1dd6a9f095a8d1d8d466e8c1543f59e9123e5f04cf61f52a6`，
  包内核对 0.1.5 / build 6、二进制 841,360 B、新符号
  `IOHIDEventSystemClientDispatchEvent` / `IOHIDEventCreateDigitizerFingerEvent` 在）。
  内容是**全局返回**（见第十节）。正文落盘 `ref/mail_0.1.5_body.txt`。

  ⚠️ **下载踩的坑（下次直接用）**：这轮 `github.com` 连不上（连接被重置），
  但 `api.github.com` 和 `objects.githubusercontent.com` 都通 ——
  所以下载 Release 附件要走 API：
  `GET https://api.github.com/repos/daofeidao/FloatingBall/releases/tags/v0.1.5`
  取 `assets[0].url`，再带 `Accept: application/octet-stream` 请求那个 url
  （302 会跳到 `release-assets.githubusercontent.com`，那个域名能连）。
  直接下 `browser_download_url`（github.com 那个）会超时。

- 0.1.4：tag `v0.1.4` → CI run `39014387848` **success** → 交付邮件 15:41 发出
  （附件已在 126 收件箱核验：`FloatingBall_0.1.4.tipa` 296.1 KB ≈ 303,232 字节）。
  内容是**震动反馈 + 首页开关**；**包含 0.1.3 的触摸修正**。
  ⚠️ **0.1.3 的触摸到底生效没有，用户还没回**（邮件末尾专门问了）——
  如果 0.1.3 点球仍无反应，下一步要换触摸那步的招（备选见第十一节）。

- 0.1.3：tag `v0.1.3` → CI run `39013572424` **success** → Release 自动创建 → 交付邮件 15:29 发出
  （附件已在 126 收件箱核验：`FloatingBall_0.1.3.tipa` 292.6 KB ≈ 299,643 字节）。
  内容是**触摸换路线**（见第十一节）+ 手势栏显示当前绑定。真机结果待用户反馈。
- 远端 main 与本地 main 仍然 SHA 不同（REST 推送构造提交），打 tag 前**必须**先问远端：
  `ref/remote_head.py`（打印远端 main 的 sha）→ 再 `ref/tag_rest.py v0.1.3 <远端 sha>`。
  0.1.3 时的远端 main = `d0f0d5c`。

- 0.1.1（外观可调）**只到 tag、没单独发**：它的 tag 轮挂在「发 Release 403」上，
  而同一个 sha 的 main 轮是成功的（main 不走发 Release 那一步），所以当时容易看漏。
  修法是 workflow 里加 `permissions: contents: write`。外观那批功能已经并进 0.1.2 一起发了。
- 0.1.2 的 Release 由 tag 构建自动创建（`softprops/action-gh-release`），Release 里的 IPA 和交付副本是同一个文件。
- **交付邮件固定格式**：从历次邮件（TT v0.9.5/v0.9.6、Helium 修改版 V3.0~V3.2、悬浮球 v0.1.0）归纳成七段式，
  模板落在 `C:\Users\lion\.workbuddy\skills\mail-126\templates\delivery_mail.md`：
  身份块（附件 / 字节数 / sha256）→ 怎么装 → 这一版做了什么（逐条带「为什么」）→ 怎么验（按顺序）
  → 还没做 / 已知问题 → 出问题看这里（日志 + 兜底）→ Release 备用链接。
  主题：`【项目名 x.y.z】一句话要点（含 IPA）`。
- 2026-10-17 13:58 **按固定格式重发了 0.1.2**（同一个包、sha256 不变；旧的那封 10:54 也在，两封都在收件箱）。
  捞历史邮件的脚本：`ref/dump_delivery_mails.py`（把带附件的邮件正文导成 UTF-8 文本，绕开控制台中文乱码）。
- 顺带记一条容易踩的：**`gh` 的 `--jq` / `--template` 参数会被 PowerShell 吃引号**
  （`select(.head_branch=="v0.1.1")` 会变成 `==v0.1.1`，jq 直接报错；Go 模板还会被当成参数解析）。
  查询改用 Python 调 `gh api` 再自己解析，脚本放在 `ref/`（该目录已 gitignore，不进公开仓库）：
  `ref/ci_status.py`（看 runs + releases）、`ref/tag_rest.py`（REST 打 tag）、`ref/watch_tag.py`（盯 tag 构建）。

## 十、系统级动作：全局返回（0.1.5 做了）/ 截图（还没做）

### 全局返回 —— 0.1.5 做了（2026-10-17 用户追加要求）

机制：**往系统里注入一次「从左缘往右划」的触摸**，效果 = 按了「上一页」。

- 实现：`src/hud/FBSystemActions.mm` 的 `FBGoBack()` / `FBHIDNoteRealEvent()`；
  动作名 `goBack`（`ShortcutAction.goBack`），HUD 的 `performAction` 转调。
- 配方来源：ZXTouch（`xuan32546/IOS13-SimulateTouch`）的 `pccontrol/Touch.xm`
  —— iOS 11~14 真机在用的触摸自动化工具。本地留了一份：`ref/ZX_Touch.xm.txt`。
  要点：父事件（hand, index 99, identity 1）+ 子事件（finger），**坐标放在子事件上**；
  坐标是**归一化 0~1、分母是屏幕的点数**；父事件要自己填 EventMask/Range/Touch
  = `0x23 / 1 / 1` 并置 `IsDisplayIntegrated = 1`；时间戳是 **uint64_t**
  （`mach_absolute_time()`，他们私有头文件就是这么声明的）。
  ⚠️ 本仓库 KIF 那份老代码写的是老式 `AbsoluteTime` 结构体 —— **两套别混着抄**。
- ⚠️ **sender ID 必须是真机那一路的**：ZXTouch 为这个专门先监听一次真触摸把它学下来，
  取不到就**拒绝注入**。我们照做：`_HUDEventCallback` 里每条原始 `IOHIDEventRef`
  喂一次 `FBHIDNoteRealEvent`（内部用 `IOHIDEventGetSenderID`），学到就缓存；
  为 0 就不注入 —— 宁可「点了没反应」，也不拿唯一一台机器赌。
- ⚠️ **三条保命写法**（改之前先读 .mm 顶部那一段）：
  ① **整串事件先全造出来再发**：造不全就一个都不发 —— 绝不允许「发了一半」
  （按下发了、抬起没发 = 屏幕上卡住一个一直按着的手指）；
  ② 手指用 `index=1 / identity=3`，**和真手指（index 0）分开**：时机算错也只影响我们这一路；
  ③ 发完 500ms 再补一条 up 兜底（`range=0/touch=0`，对真手指无影响）。
- ⚠️ **落点必须避开球自己**：不避开的话，球会把自己注入的划动当成「用户在拖它」
  → 球乱跑，甚至自己触发自己。所以 `FBGoBack(CGRect)` 收球的屏幕矩形，
  落点 y 挑一个不撞它的位置（球不在左半边时直接用竖直中点）。
- ⚠️ 坐标是「**竖屏归一化**」（宽高都按竖屏点数算）：横屏时划的位置在显示上不是左缘，
  结果是「点了没反应」，**无危险**。先不治。
- 冷却：0.6 秒内只注入一次（防手抖连点 / 两个手势撞一起）。
- 副作用可控：注入的触摸球自己也会在 HID 回调里看到，但落点避开了球 →
  我们只在「按下落在球上」时接管 → 天然不会自己触发自己。
- **App 那边不执行这个动作**（`AppsTab.run`）：这时候 App 自己是前台，划出来没地方可返回，
  所以只弹一句说明，让用户去手势里绑。

### 截图 —— 还是没做（别当成漏做）

要么把 SpringBoard 的二进制 dlopen 进来调它的单例（后果不可控），
要么模拟「电源 + 音量加」的组合 HID 事件。网上现成配方没有一条是
「iOS 15.6.1 上确定可用」的，所以继续押着（当初押后全局返回是同一个理由）。

### 顺带说明：0.1.4 及以前那条「替代方案」已经过时

那时说「球不吃球以外区域的触摸，所以在球以外的地方左缘右划本来就是 App 自己的返回手势，
够用了」—— 那要用户自己划；0.1.5 起可以把手势绑成「全局返回」，让球替用户划。


## 十一、触摸是怎么进来的（2026-10-17 真机定案，别再改回去）

### 结论一句话

**SpringBoard 托管的那个全局窗口只会「显示」，不会收到触摸。**

「窗口能显示 → 窗口也能被点中」这个假设是错的，0.1.0~0.1.2 就卡在这：
球浮在每个界面都正常，但点它**数字一个都不涨**（= 一个触摸事件都没进我们进程），
把 `HUDMainWindow` 的 `_ignoresHitTest` 从 `YES` 改成 `NO` 也一样。

### 现在的做法：全局 HID 事件 → 自己喂给球视图

代码位置：`src/hud/HUDApp.mm` 的 `_HUDEventCallback`（`USE_HID_EVENT_CALLBACK = 1`）。

1. `BKSHIDEventRegisterEventCallback(_HUDEventCallback)` 注册全局 HID 回调
   （`BackBoardServices` 已经在 Makefile 里链着）；
   ⚠️ **这条路 0.1.7 起只当备用**：0.1.6 真机自检证明它在 15.6.1 上收不到任何事件，
   新的主路是 `IOHIDEventSystemClient` 监视客户端（见本节末「0.1.7」）。
2. 每个 HID 事件用 `AXEventRepresentation` 翻成「坐标 + 阶段 + 触点 id」；
3. 判断「这一下是不是按在球上」：拿球视图的 `bounds` → `convertRect:toView:window`
   → 加上 `window.frame.origin` 得到**屏幕坐标**矩形，再往外放 6pt；
4. 是 → `TSEventFetcher receiveAXEventID:...`（Lessica/TrollSpeed 那份）把它喂成真正的 `UITouch`；
5. 之后 `BallRootViewController` 里那几个标准手势识别器就正常工作了。

⚠️ 三个坑（踩过 / 差点踩）：

- `TSEventFetcher` 的参数**叫** `atGlobalCoordinate`，内部却是 `setLocationInWindow:` ——
  **必须传窗口坐标**。Helium 的窗口是全屏的，两种坐标正好一样，照抄必踩。
- 只有「按下」落在球上才接管；接管之后该触点的 move / up **全归我们**
  （手指划出球的范围也不能丢，否则拖动断在半路、还会留下半截触摸）。
- 我们**只能看、不能吃掉**事件：点在球上时，球下面的 App **也会**收到这一下。
  这是 HID 回调本身的限制。真要治，得走「往系统里发取消事件」那套（`IOHIDEventCreateDigitizerEvent`），
  风险和第十节那两个动作同级，另开一轮做。

### 安全上的收获（顺手把一个风险去掉了）

既然触摸不靠窗口，`HUDMainWindow._ignoresHitTest` 就改回 **`YES`**（和 Helium 一样）：
窗口**绝不参与命中测试** → 从根上不可能吞掉屏幕触摸。
窗口尺寸仍然只有球那么大，算第二层保险。这比 0.1.2 更安全。

### 排查触摸问题看这几行日志

| 日志行 | 说明 |
|---|---|
| `触摸回调已绑定球视图 frame=…` | 球视图注册上了（`FBHUDSetBallView` 被调到） |
| `触摸：按下落在球上（屏幕 x,y）→ 接管触点 n` | **最关键**：按在球上的那一下真的进来了 |
| `触摸：触点 n 抬起/取消，交还` | 这次触摸正常收尾 |
| `轻点：计数=n 绑定=…` | 手势识别器工作（`BallRootViewController` 记的） |

点球时连「按下落在球上」都没有 → HID 回调那条路没生效；
有它但没有「轻点」→ 「喂给视图」那一步有问题。

### 触摸自检（0.1.6 加，用户报「点球直接穿透」之后做的）

这条链子的毛病是**一路静默**：断在①~⑤任何一段，用户看到的现象都一模一样（球不动）。
所以 0.1.6 把每段的计数写一份到 **`/tmp/FloatingBall.probe`**（限速 1 秒 1 次，
**只写这一个文件，绝不碰设置那份 plist**），**App 的「关于」页**读出来显示（带「刷新」按钮）
—— 用户在手机上不用开终端就能把这一行念给我。

分段（`FBProbeWrite` / `FBProbeNote`，都在 `HUDApp.mm`）：

| 段 | 计数 | 断了说明什么 |
|---|---|---|
| ① | `回调=` | 两条路加起来收到几次 HID 事件；**一直是 0 = 一条事件都没进我们进程** |
| ① | `路A=` `路B=` | 这些事件分别是哪条路送来的：A = 老的 `BKSHIDEventRegisterEventCallback`，B = 0.1.7 新加的 `IOHIDEventSystemClient` 监视客户端 |
| ① | `匹配服务=` | 监视客户端按 `PrimaryUsagePage 13 / PrimaryUsage 4` 匹配到几个触摸屏服务（`-1` = 没问；**正常是 1**；**0 = 连匹配都没匹配上，那肯定收不到**） |
| ② | `无rep=` | `AXEventRepresentation` 转不出来（类没加载 / 方法签名不对） |
| ③ | `无路径=` | `[[rep handInfo] paths]` 是空（非触摸事件，或只有父事件） |
| ③ | `id<=0=` | `pathIdentity <= 0`（**0.1.6 起当 1 用**，不再整条丢弃） |
| ④ | `不在球=` | 按在球外（本来的设计）⭐ 这行会打印**当时的点和球的矩形** → 坐标口径问题一眼看出 |
| ④ | `非本触点=` | `isTouchDown` 一直是 0 → 永远进不了「接管」分支 |
| ⑤ | `接管=` `喂球=` | 接管了、喂给 `TSEventFetcher` 了 |
| —— | `另一条路=` | 两条路都活着时，**非活跃**那条又送来的触摸（只计数，不喂，防同一根手指喂两遍） |
| —— | `最后：` | 最后停在哪一段（带坐标） |

同时启动时先写一份「全是 0」的，好区分「回调从来没被调过」和「球进程根本没起来」。
另外**头 3 条**事件会原样进日志：`HID#n etype=… paths=… id=… down=… 点=(x,y)`
（`etype` 11 = 触摸；能一眼看出「压根没收到触摸事件」和「收到了但没认出来」）。

### ⚠️ 硬规则：HID 回调里**绝不做 dlopen**

`FBHIDNoteRealEvent` 是在 `_HUDEventCallback` 里调的，而那是 **backboardd 的事件线程**。
0.1.5 让它内部走 `FBLoadHID()`（`dlopen` IOKit + 一排 `dlsym`），
一旦加载被卡住，回调就再也出不来 —— 现象正好是**「点球直接穿透、球完全不响应」**。
0.1.6 起：

- 加载**只在 `FBPrepareHID()`** 里做：HUD 启动时（`BKSHIDEventRegisterEventCallback` **之前**）调一次，
  `FBGoBack`（在 HUD 主线程）动手前也会再调一次（那时安全）；
- 回调里只看 `gFBHIDReady` 这个标志位，没准备好就直接返回；
- `FBHIDEventTypeOf()` 同理（只看标志位，不做加载）。

**以后往 `_HUDEventCallback` 里加东西，先问一句：这里会不会触发加载 / 阻塞 / 等锁？**

### 0.1.7：老路被真机证伪，换 `IOHIDEventSystemClient` 监视客户端

**用户 2026-10-17 念回来的自检**：`回调=0 无rep=0 无路径=0 … 接管=0 喂球=0`，
`最后：` 还是那句「还没收到过任何 HID 事件」，**按音量键也不涨**。

→ 结论：`BKSHIDEventRegisterEventCallback` 这条路在 iOS 15.6.1 上
**一条事件都收不到**。不是坐标算错、不是球没接住，是**源头不来事件**。

**为什么抄错了**：这份代码的源头是 Helium ← TrollSpeed ← UIDaemon。
在 GitHub 上把这条脉全翻了一遍（Lessica/TrollSpeed、huami1314/DarkSpeed、
iamjhe08/VidGrab……）——**每一份的声明和用法都一模一样，而且没有人验证过它真能收事件**
（它们的 HUD 只用来「显示」，触摸是遗留代码）。Helium 的 HUD 里
`addGestureRecognizer:` / `touchesBegan:` **一个都没有** —— 这条路的「能用」从来没有证据。

**0.1.7 的做法：两条路一起听，谁先送来触摸谁生效**（`HUDApp.mm`）

| 路 | 做法 | 依据 |
|---|---|---|
| A（老，留着计数） | `BKSHIDEventRegisterEventCallback(_HUDEventCallback)` | Helium/TheBall 同款，实测收不到 |
| B（新，主用） | `IOHIDEventSystemClient` **监视**客户端：`IOHIDEventSystemClientCreateWithType(alloc, 1, NULL)` → `SetMatching({PrimaryUsagePage:13, PrimaryUsage:4})` → `RegisterEventCallback` → `ScheduleWithRunLoop(CFRunLoopGetMain(), kCFRunLoopDefaultMode)` | macPad 的 `misc/ios_hid_touch_probe.m`（作者照 **iOS 16.3.1 反汇编**写的观察+注入程序）、ZXTouch 的 `pccontrol/Touch.xm` |

要点：

- 两条路的回调签名**本来就一样**（`(target, refcon, service, event)`），共用一个
  `FBHandleHIDEvent(route, …)`；`_HUDEventCallback` / `_HUDMonitorRouteCallback` 只是薄壳。
  → 说明当年 Helium 那位作者大概是**把 IOHIDEventSystemClient 的回调类型安到了 BKS 的函数上**。
- 「监视」类型（`type=1`）是**只看不吃**，不会把系统事件截下来（第六节末尾那条安全底线不受影响）。
- 匹配字典**只写 13/4 两个键**（不写 `Transport`/`Built-In`，少写一点匹配面更大）；
  匹配到几个服务用 `IOHIDEventSystemClientCopyServices` 数出来，写进自检的 `匹配服务=`。
- **同一根手指不能被喂两遍**：第一条触摸事件来自哪条路，哪条就是「活跃路」，
  另一条之后只累加 `另一条路=`。
- 顺手替老路补一次机会：BKS 注册函数的返回值**如果类型是 IOHIDEventSystemClient**
  （`CFGetTypeID` 比对 + 指针下限 `0x100000000` 两道检查，够不着就**不碰**），
  就替它 `SetMatching` + `ScheduleWithRunLoop` —— 万一老路就差这一步。
- ⚠️ 回调里**依然绝不做 dlopen**（硬规则不变）：监视客户端那几个符号在
  `FBStartHIDMonitor()` 里启动时取，回调里只调函数指针。

**还没验证的**（下一版看用户回报）：路B 能不能真收到事件。
如果 `匹配服务=0` → 匹配写错；`=1` 但 `路B=0` → 权限/投递问题；`路B` 涨而 `接管=0` → 看 `最后：` 的坐标与球矩形。

