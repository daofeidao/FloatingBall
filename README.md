# 悬浮球 FloatingBall

iPhone 上的**全局悬浮球**：浮在所有 App 之上，轻点/双击/滑动/长按各不相同，可拖动吸边。

- 只支持 **TrollStore（巨魔）** 安装。普通签名（AltStore/Sideloadly/企业证书）**装不了** ——
  它需要一组特权 entitlements，只有巨魔能给。
- 真机验证环境：**iPhone 13 Pro Max / iOS 15.6.1**。

## 怎么做到的

系统不允许 App 画在别的 App 之上。这里的做法是：

1. App 用 `posix_spawn` **把自己再启动一次**（argv 带 `-hud`），这次以 **root** 常驻；
2. 这个进程带着一整套**抄自系统 `assistivetouchd` 的 entitlements**
   （`com.apple.assistivetouch.daemon`、`com.apple.springboard.accessibility-window-hosting` 等）；
3. 它通过 `SBSAccessibilityWindowHostingController` 向 SpringBoard 注册一个全局窗口。

也就是「拿到系统小白点的工作证」。**不需要越狱。**

### 触摸是怎么送进来的（0.1.8 定案，重要）

**结论：窗口自己必须参与命中测试（`_ignoresHitTest = NO`），触摸才会被送进这个进程。**
走到这个结论绕了两圈，过程值得留着（都是为了以后别再绕回去）：

| 版本 | 做法 | 真机结果 | 当时为什么误判 |
|---|---|---|---|
| 0.1.0~0.1.2 | `_ignoresHitTest = YES`（窗口不参与命中测试，抄 Helium） | 点球没反应 | —— |
| 中途试过 | 改成 `NO` | 还是没反应 | ⚠️ **那时候球上还没有手势识别器**：触摸就算送进来了也没人接。「没人接」被误读成了「收不到触摸」 |
| 0.1.3~0.1.7 | 放弃窗口，改去听全局 HID 事件、自己喂假触摸给球 | 0.1.6 自检证明 `回调=0`：那个 API 一条事件都收不到 | 抄的是 TheBall / Helium 的代码，而它们的 HUD 只用来「显示」，那段代码**从没被验证过** |
| **0.1.8** | **`_ignoresHitTest = NO`，触摸直接走球自己的手势识别器** | 待验 | 依据：逐条反汇编 TheBall 2.7 的 `HUDMainWindow`（同机型、同签名权限、它的球确实可点可拖） |

0.1.8 的判断依据（TheBall 2.7 反汇编对照）：

| 覆盖的方法 | TheBall | 我们 |
|---|---|---|
| `-_ignoresHitTest` | **NO** | 0.1.8 起 NO（原来是 YES） |
| `-_isWindowServerHostingManaged` | NO | NO（一直是对的） |
| `+_isSystemWindow` | YES | YES（一直是对的） |
| `-_isSecure` / `-_shouldCreateContextAsSecure` | YES | 暂时没抄：跟「摸没摸到」无关，一次只改一条 |
| 窗口注册 | `SBSAccessibilityWindowHostingController` + `NSInvocation` 调 `registerWindowWithContextID:atLevel:`（类型编码 `v@:Id`，level 传 `window.windowLevel`） | 一模一样 |

**老路（全局 HID 事件）保留为备份**，但不主动喂了。判据在 0.1.11 收紧过一次：
0.1.8 用的是「窗口被问到命中测试且落在球上」，但**「触摸进了窗口」不等于「手势认出来了」**——
万一只是进了窗口没认出，两条路会同时被关死，球彻底没反应。0.1.11 起只有
**球的手势真的触发过**（自检里「真点击」> 0）才停喂合成触摸。

### 0.1.11：为什么老路一条「按下」都接不到（真机读数对码的结论）

0.1.8 的自检读数：`回调=30225（路A=0 路B=30225 匹配服务=1）无rep=0 无路径=0 不在球=0
非本触点=29458 接管=0 喂球=0`。

**事件全收到了，但 `[rep isTouchDown]` 一次都没为真** —— 而老逻辑只有认出「按下」才接管，
所以永远接管不了。这就是「点球没反应」的直接成因（对着能用的 TheBall 反汇编对齐确认：
它也是这套事件、这个标志）。

0.1.11 的改法（`HUDApp.mm`）：

| 环节 | 0.1.8（旧） | 0.1.11（新） |
|---|---|---|
| 「按下」从哪来 | 只信 `[rep isTouchDown]`（实测恒 0） | **自己定**：起手落在球上就算 `Began`（TheBall 同款思路） |
| 「抬起」从哪来 | AX 的 `isLift` / `isInRangeLift` | 底层 IOHID 字段 `Touch=0 且 Range=0`（连续两条，防一次点击被拆成几下）/ AX lift / **1.2 秒断档兜底**（补一个 `Ended`） |
| 手指坐标的坐标系 | 当**屏幕坐标**用 | 屏幕解释 / 窗口解释**两种都试**（我们窗口只有球那么大，赌错就永远「不在球上」） |
| 要不要继续喂合成触摸 | 窗口问到了就停 | **真点击 > 0** 才停 |
| 接管的起始条件 | 必须是「按下」 | 起手在球上 **且** 底层字段没说「没手指」（`Touch != 0`），并排除 (0,0) 那个假点 |

字段含义来自真机在用的注入工具 ZXTouch（`pccontrol/Touch.xm`）：它造「按下」时填
`Range=1 Touch=1`、「移动」填 `Range=1 Touch=1`、「抬起」填 `Range=0 Touch=0`。
自检里因此多了一行 `底层：AX按下=A 在屏=B 离屏=C`，以及「最后」一行带原始 mask。

所以 0.1.3 换另一条路（源头同样是 TrollSpeed → Helium）：

1. 用 `BKSHIDEventRegisterEventCallback` 监听**全局 HID 事件**（有 assistivetouchd 权限才拿得到）；
2. 每个事件算一下「这一下是不是按在球上」（球在屏幕上的矩形往外放 6pt）；
3. 是，就把这个事件**喂成一次真正的 `UITouch`** 给球视图
   （`src/helpers/ts/TSEventFetcher.mm`，来源 Lessica/TrollSpeed）——
   之后 `UITapGestureRecognizer` / `UIPanGestureRecognizer` 这些就正常工作了。

> ⚠️ **第 1 步那个 API 在真机上一条事件都收不到**（0.1.6 的「触摸自检」实测：
> `回调=0`，按音量键也不涨）。TrollSpeed / Helium / TheBall 全是同一份代码，
> 而它们的 HUD 只负责「显示」，所以那条路其实**从来没被验证过**。
>
> 0.1.7 起改用**两条路一起听**，谁先送来第一条触摸事件谁生效（另一条只计数，防重复喂）：
>
> | 路 | 做法 | 依据 |
> |---|---|---|
> | A（老） | `BKSHIDEventRegisterEventCallback` | Helium/TheBall 同款；实测收不到 |
> | B（新） | `IOHIDEventSystemClient` **监视**客户端：`CreateWithType(alloc, 1, NULL)` → `SetMatching(13/4)` → `RegisterEventCallback` → `ScheduleWithRunLoop(主 runloop)` | macPad 的 `misc/ios_hid_touch_probe.m`（按 iOS 16.3.1 反汇编写的）、ZXTouch 的 `pccontrol/Touch.xm` |
>
> 「监视」类型（type=1）是**只看不吃**，不会把系统事件截下来。

两个副作用（0.1.3~0.1.7 那几版）：

- 窗口的 `_ignoresHitTest` 当时是 `YES`：**它绝不参与命中测试**，
  等于把「万一吞掉整屏触摸」的风险从根上去掉。尺寸仍然只有球那么大，算第二层保险。
  ⚠️ 0.1.8 起改成 `NO`（见上一节）——**安全阀改成靠这两条**：窗口只有球那么大、
  根视图是 `FBPassThroughView`（球以外一律 `NO`，漏给下面的 App）。
- HID 回调**只能看、不能吃掉**事件：点在球上时，球下面那个 App **也会**收到这一下。
  ⚠️ 这是「喂假触摸」那条路的限制；0.1.8 的真触摸路没这个问题（落在球上的一下被我们自己吃掉，
  落在球外的照常给下面的 App）。

> ⚠️ 坐标别抄错：`TSEventFetcher` 那个参数虽然叫 `atGlobalCoordinate`，
> 内部其实是 `setLocationInWindow:` —— 必须传**窗口坐标**。
> Helium 的窗口是全屏的，两种坐标正好一样，直接照抄会一个点都命中不了。


> 骨架沿用 [Helium](https://github.com/leminlimez/Helium)（GPL-3.0），
> 机制源头是 [TrollSpeed](https://github.com/Lessica/TrollSpeed) 与 [UIDaemon](https://github.com/limneos/UIDaemon)。

## 构建

本地（Windows）**不能编译**，只能靠 CI：

```
写代码 -> push -> GitHub Actions (macos-14 + Xcode 15.1 + theos) -> build/FloatingBall.tipa
```

打 tag（`v0.1.1` 这样）会发布 Release 并附带 `FloatingBall.tipa`。
版本号唯一真源是 `layout/Applications/FloatingBall.app/Info.plist` 的 `CFBundleShortVersionString`，
⚠️ tag 必须和它一致，CI 里有断言。

改图标 / 球的样子：`python scripts/make_icon.py`（自己画 PNG，不依赖 Pillow）。
想先看效果：`python scripts/preview_styles.py` → `ref/style_preview.png`（不参与打包）。

### 屏幕上的球是谁画的

由 `src/controllers/BallRenderer.swift`（Swift + Core Graphics）按
「形状 + 颜色 + 自定义图片」当场画出来，写到
`/var/mobile/Library/Preferences/com.daofeidao.floatingball.ball.png`；
悬浮球进程只做一件事 —— 读这个文件显示。

> 为什么要绕这一圈（而不是直接在 HUD 里画）：**画图只写一份代码**。
> App 里的「预览」和屏幕上的「球」调的是同一个函数，
> 所以不会出现「设置里看着是白的、屏幕上还是黑的」。
> ⚠️ 代价：`BallRenderer.swift` 的比例参数必须和 `scripts/make_icon.py` 保持一致
> （桌面图标固定用「小圆点」那一套）。

打包进 App 的那 3 张 PNG 现在有两个用途：**设置界面的缩略图**，
以及 `BallDot.png` 当兜底贴图（App 第一次装完、还没写过贴图时，球先用它）。

| 形状 | 缩略图 | 说明 |
|---|---|---|
| 小圆点 | `BallDot` | **默认**，照 iPhone 自带的辅助触控小圆点画的（桌面图标也是它） |
| 纯色 | `BallPlain` | 一个干净的半透明圆，颜色随便换 |
| 白点 | `BallWhite` | 预设：不透明的白点，深色壁纸 / 夜里更容易看见（颜色固定） |
| 自定义 | 相册选的图 | 用你自己相册里的图片，自动裁成圆形 |

设置键（都在共享 plist 里）：

| 键 | 值 | 说明 |
|---|---|---|
| `BallShape` | `dot` / `plain` / `white` / `custom` | 形状 |
| `BallColor` | `#RRGGBB` | 颜色（`white` 和 `custom` 用不到） |
| `BallSize` | 32~100 | pt，HUD 侧硬限 24~160 |
| `BallOpacity` | 0.3~1.0 | 整个球的透明度，HUD 侧硬限 0.3~1.0 |

**大小 / 不透明度不重画贴图**（贴图里所有比例都是相对直径的，HUD 拉伸 + 设 alpha 就够）；
**形状 / 颜色 / 自定义图**才重画 —— 否则拖滑块时每动一下都要编码一次 PNG，界面会卡。

环和十字用「对比色」（身子深就画白、身子浅就画黑），
所以颜色可以随便选，换成白色就自然出来「白点」那种效果。

## 怎么验证 v0.1

1. **装**：`FloatingBall.tipa` 传到手机 → 用巨魔（TrollStore）打开安装。
2. **开**：打开 App → 第一栏「启动」→ 把「启动悬浮球」打开。
   状态应变成「运行中」，屏幕上（右侧靠边、垂直居中）出现一个圆球
   （默认就是和系统小白点一样的那个）。
3. **验**：
   - **浮在最上层**：切到别的 App（微信、设置随便），球还在 → 这一条过了，整个形态就成立。
   - **点得到**：轻点球 → 计数 +1 并且打开「设置」；回 App 里看「轻点次数」。
   - **拖得动**：按住球拖到别的位置，松手会吸到左/右边缘；杀进程重开，位置还在。
   - 双击 = 计数清零；长按 = 显示/隐藏数字。
   - **换样子**：「图标」栏点另外几个缩略图、点颜色圆点（或系统取色器）、
     选「自定义」从相册挑一张图，球应立刻变（不用重开）。
   - **改大小**：拖「大小」滑块（32~100pt），球应立刻跟着变；方块里的预览就是实际大小。
   - **调不透明度**：拖「不透明度」滑块（30%~100%），球应立刻变淡/变实。
   - **手势绑定**：「启动」页「手势」一栏，单击/双击/长按各点开选一个动作，回桌面点球看效果。
   - **快捷菜单**：第二栏（0.1.9 起从「快捷应用」改名）。点「添加」可以加 App、内置动作、URL 协议
     （微信扫一扫 / 支付宝扫一扫 / 微信收付款码是内置的）或系统快捷指令；点那一行就执行。
     **排序**：按住一行拖到别处就换顺序（右边那三条横线就是手柄，没有「编辑」按钮了）；左滑删除。
   - **震动**：点球、球落位、执行动作时应各震一下；「启动」页的「震动反馈」开关能关掉它（关了就不震），
     开关旁边有「试一下震动」按钮可以当场试。
   - **全局返回**：把某个手势绑成「全局返回」→ 去「设置」里点进一个二级页面 → 回桌面点球，
     页面应该「退回去」。⚠️ 先拿「设置」这种没有未保存内容的页面试，别在写了一半的地方试。
4. **关了**：把开关关掉，球消失。

## 快捷列表 / 手势 / 刷新信号（0.1.2）

**数据都在共享 plist 里**，App 和悬浮球进程读同一份：

| 键 | 内容 |
|---|---|
| `Shortcuts` | 快捷列表：`[{kind: app 或 action 或 url, id, title, icon(可选)}]` |
| `GestureTap` / `GestureDoubleTap` / `GestureLongPress` | 每条手势绑一个 key：`app:bundleID` / `action:动作名` / `url:整条URL` |
| `ShowLabel` | 球上的数字显示不显示 |
| `HapticsEnabled` | 震动反馈开关（默认开，见下面「震动反馈」一节） |
| `PendingTab` | HUD 让 App「起来后落在哪一栏」，App 读完就清掉 |

**存的是 key，不是下标** —— 快捷列表增删排序都不会把手势绑定搞乱。

### 快捷菜单那一栏（0.1.10 起能拖、能加 URL）

- **排序**：没有「编辑」按钮（0.1.9 及以前的右上角「编辑」已去掉）。
  每行右边那三条横线就是拖动手柄 —— 手指按住一行拖到别处就换顺序，松手才写盘。
  点一下照样执行，左滑照样删除。
  ⚠️ 不用系统的编辑模式做这件事：编辑模式的删除圈和「左滑删除」重复，
  而且编辑模式下点一行**不会**执行动作。
- **添加页**（「添加」按钮）依次是：内置动作库 → **添加** → 已安装的 App。
  中间那栏「添加」里有「系统快捷指令」和「URL 协议」两块，**都在同一页**（没有二级页面、没有折叠）。

内置动作：

| 动作 | 干什么 |
|---|---|
| 刷新信号 | 让基带重新注册、重新搜网（卡贴机没信号/假信号时用，见下） |
| 打开悬浮球 / 打开快捷菜单 | 拉起 App 并落在对应那一栏 |
| 截屏（0.1.9） | 先走系统的截图服务，取不到才注入「音量加 + 电源」组合键（见上面「截屏」一节） |
| 移动悬浮图标 | 球高亮进入「移动模式」，拖一下落位；点一下退出（防误触） |
| 显示/隐藏数字 | 球上那个数字 |
| 什么都不做 | —— |

### URL 协议 / 系统快捷指令（0.1.10）

「快捷菜单」里可以放两类 URL 项（`kind = url`，`id` 就是一整条 URL）：

| 项 | URL | 备注 |
|---|---|---|
| 微信扫一扫 | `weixin://scanqrcode` | 内置 |
| 支付宝扫一扫 | `alipayqr://platformapi/startapp?saId=10000007` | 内置 |
| 微信收付款码 | `weixin://widget/pay` | 内置 |
| 系统快捷指令 | `shortcuts://run-shortcut?name=<指令名字>` | 在添加页填名字，**Apple 官方的 scheme** |

- 这四条都**查证过**（2026-10-17）：微信/支付宝那三条见上面的表（和 MEMORY §七 那份 URL 表一致），
  系统快捷指令见 Apple《Shortcuts User Guide · Run a shortcut using a URL scheme》。
- 打开走 `FBOpenURL()`（`hud/FBSystemActions.mm`）：`LSApplicationWorkspace -openURL:withOptions:error:`
  → `-openSensitiveURL:withOptions:` → `UIApplication -openURL:options:completionHandler:`，取不到就往下一档退。
- ⚠️ 返回 YES **只代表「系统收下了」**，不代表对面真的执行了：
  比如系统快捷指令的名字写错，是「快捷指令」App 自己弹「找不到」。
- URL 项**也能绑到手势上**（「启动」页手势那一栏现在列 App 和 URL 两类）。

### 刷新信号是怎么做的

调 CoreTelephony 的私有函数（**dlsym 取符号，不直接链接**）：

```
_CTServerConnectionCreate(kCFAllocatorDefault, NULL, NULL)
_CTServerConnectionResetModem(conn, CFSTR("UserTriggeredReload"))
```

需要 `ent.plist` 里有 `com.apple.CommCenter.fine-grained = [ "spi" ]`，
没有这个权限 CommCenter 会把请求**直接丢掉**（连报错都没有）。
做法来源：[DevelopCubeLab/TrollSIMSwitcher](https://github.com/DevelopCubeLab/TrollSIMSwitcher)（Apache-2.0）。

⚠️ **这个 API 没有结果**：请求发出去就结束了，成没成只能看状态栏的信号格。
所以日志里只会写「已请求重置基带」，不会写成功还是失败 —— 这是 API 本身决定的。

⚠️ 它只是让基带重载重新搜网，**不碰卡贴、不碰 IPCC、不改锁频**。
卡贴机真掉信号时，光刷新经常不够，一般还要配合拨 `*` 取激活信号 / 重刷 IPCC / 切卡槽。

### 全局返回（0.1.5 做了）

用户 2026-10-17 追加：「增加一个，全局返回，能在手势功能中选择可以添加」。

做法：**往系统里注入一次「从左缘往右划」的触摸**
（`IOHIDEventCreateDigitizerEvent` + `IOHIDEventSystemClientDispatchEvent`，全部 dlsym），
效果和用户自己从左边缘往右划一样 —— 也就是「上一页」。

⚠️ **这是全项目唯一一个能伤到系统本身的动作**。三条保命写法写在
`src/hud/FBSystemActions.mm` 顶部，改之前先读：

| 保命写法 | 为什么 |
|---|---|
| **先把整串事件全造出来，再开始发** | 只要有一个造不出来就整串放弃、一个都不发 —— 绝不允许「发了一半」（按下发了、抬起没发 → 屏幕上卡住一个一直按着的手指） |
| 手指用 `index=1 / identity=3` | 和真手指（index 0）分开：抬起时机算错也只影响我们这一路，动不到用户的手 |
| 发完 500ms 再补一条「抬起」兜底 | `range=0/touch=0`，对真手指无影响 |

还有一条容易漏的：**落点必须避开球自己**。不避开的话，球会把自己注入的划动
当成「用户在拖它」→ 球乱跑，甚至自己触发自己。所以 `FBGoBack` 要收球的屏幕矩形，
落点 y 会挑一个不撞它的位置。

配方来源：[xuan32546/IOS13-SimulateTouch](https://github.com/xuan32546/IOS13-SimulateTouch)
（ZXTouch，iOS 11~14 真机在用的触摸自动化工具）的 `pccontrol/Touch.xm`。照抄的要点：

- 每个事件是「父事件（hand，index 99，identity 1）+ 子事件（finger）」两层，**坐标放在子事件上**；
- 坐标是**归一化 0~1**，分母是屏幕的**点数**（他们那边算的是像素 ÷ scale，等价）；
- 父事件上要自己填 `EventMask / Range / Touch`（`0x23 / 1 / 1`），并置 `IsDisplayIntegrated = 1`；
- ⚠️ **sender ID 必须是真机那一路的**：他们为这个专门先监听一次真触摸把它学下来，取不到就拒绝注入。
  我们照做（`FBHIDNoteRealEvent`，由 HUD 的 `_HUDEventCallback` 每条事件喂一次）。
- ⚠️ 时间戳按 `uint64_t` 传（`mach_absolute_time()`）—— 他们那份私有头文件就是这么声明的；
  本仓库 KIF 那份老代码用的是老式 `AbsoluteTime` 结构体写法，**两套别混着抄**。

**万一界面卡住点不动**：长按「电源 + 音量减」强制重启即可恢复
（球不是开机自启的守护进程，重启就没了，不留残留）。

### 截屏（0.1.9 做了）

用户 2026-10-17 追加：「内置动作库+【截图】功能」。

两条路，**先走安全的那条，取不到才兜底**（实现在 `src/hud/FBSystemActions.mm`
的 `FBTakeScreenshot()`，日志前缀「截屏：」）：

| 路 | 做法 | 风险 |
|---|---|---|
| ① `ScreenshotServices`（优先） | dlopen 这个私有 framework，用 `SSScreenCapturer` + `SSScreenCapturerPresentationOptions(setPresentationMode:NO)` 截一张、直接存相册；先用 `SSScreenCaptureAbilityCheck +isAbleToTakeScreenshots` 问系统允不允许 | **不注入任何输入** —— 没有「卡住一根手指 / 一个按键」的风险 |
| ② 注入「音量加 + 电源」组合键（兜底） | `IOHIDEventCreateKeyboardEvent`（consumer page `0x0C`，usage `0x30`=Lock / `0xE9`=VolumeUp），和全局返回同一套注入机制 | 和全局返回同级；电源只按 60ms，**万一没被认成组合键 → 结果只是锁屏**，解锁继续用，不丢东西 |

为什么 ① 优先：iOS 11 起截图这套能力从 SpringBoard 搬进了 `ScreenshotServices`，
SpringBoard 自己的 `-takeScreenshotAndEdit:` 和**辅助触控的「截屏」**都是调它 ——
辅助触控跟我们一样是独立进程，所以这条路是「有据可查」的。
私有类一律 `dlopen` + `NSClassFromString`（取不到只是返回 nil，不会链接失败），
整个过程包在 `@try` 里：真抛异常只影响我们自己这个进程（球进程崩了 = 球消失，
去 App 把开关关一下再打开就回来，不动系统）。

②的用法号来自 Apple Wiki 的 iPhone 按钮 HID 表（`12/0x30`=Lock、`12/0xe9`=Volume
Increase），并且严格遵守全局返回那三条保命写法：**四条事件先全造出来再发**
（造不全一个都不发）、用真机那一路 sender ID、发完 600ms 再补两条「松开」。
2 秒冷却，防手抖连点。

⚠️ 两条都没走通时（`FBTakeScreenshot()` 返回 0），日志里会列出这台系统上
**实际存在**的私有类（`SBScreenShotter` / `SSMainScreenSnapshotter` …），
给下一版指路 —— 相当于让用户的手机帮我们做一次侦察。

### ⚠️ 万一手机变得点不动了

**长按「电源 + 音量减」强制重启即可恢复。**

悬浮球进程**不是开机自启的守护进程**，重启就彻底没了，不需要卸载、不会留残留。

（为什么会有这个风险：球靠 `assistivetouchd` 那张工作证借了 SpringBoard 的一个层级。
如果 SpringBoard 把我们的窗口当成整屏的，就会吞掉整块屏幕的触摸。）

0.1.8 起这条风险的位置变了：窗口 `_ignoresHitTest = NO`（必须这样，否则收不到触摸），
安全阀改成两层 —— ① 尺寸仍然只有球那么大；② 根视图 `FBPassThroughView` 对球以外的点
一律返回 `NO`（漏给下面的 App）。
代价是一圈 6pt 的「宽容区」会吃掉落在球边上但没点中球的那一下（设计如此：手指没那么准）。
真出事了（屏幕点不动）的兜底：**长按「电源 + 音量减」强制重启**，重启后球不会自己回来。

## 怎么判断触摸到底进没进来

### 手机上看「触摸自检」（0.1.6 加，0.1.8 补了「真触摸」那行，不用开终端）

触摸这条链子**一路静默**：断在任何一段，表现都一模一样（点球没反应）。
所以球进程会把每一段的计数写一份到 `/tmp/FloatingBall.probe`，
**App 的「关于」页**直接读出来显示（那里有个「刷新」按钮）。

第一行是「全局 HID 事件」那条链（0.1.3~0.1.7 的路）：

| 字段 | 链子上的哪一段 |
|---|---|
| `回调=` | ① HID 回调被调了几次（有没有收到事件；一直是 0 = 一条事件都没进来） |
| `路A=` `路B=` | ① 这些事件分别来自哪条路：A = 老的 `BKSHIDEventRegisterEventCallback`，B = 新的 `IOHIDEventSystemClient` 监视客户端（0.1.7 加） |
| `匹配服务=` | ① 监视客户端按「digitizer/touchscreen」匹配到几个触摸屏服务（-1 = 没问；0 = 一个都没匹配上，那肯定收不到） |
| `无rep=` | ② `AXEventRepresentation` 转不出来 |
| `无路径=` | ③ 没有手指路径（按键 / 只有父事件都走这里） |
| `id<=0=` | ③ `pathIdentity <= 0`（现在**当 1 用**，不再整条丢掉） |
| `不在球=` | ④ 按下的位置不在球的矩形里（这行是本来的设计，不是 bug） |
| `非本触点=` | ④ 不是我们接管的那一下（`isTouchDown` 一直是 0 就会一直掉这里） |
| `另一条路=` | 两条路都活着时，非活跃那条又送来的触摸（只计数，不喂，防重复） |
| `接管=` `喂球=` | ⑤ 接管了、喂给球视图了 |

第二行是「真触摸」那条链（0.1.8 起，也是**现在的主路**）：

| 字段 | 说明 |
|---|---|
| `窗口问=` | 系统问过窗口几次「这个点是不是你的」（= 真有触摸问进这个进程了）。**这是最关键的一个数** |
| `落在球=` | 其中落在球（含 6pt 宽容区）上的次数 |
| `真点击=` | 球自己的单击手势真的触发了多少次 |

读法：

- `真点击>` 0 → 这条路通了（点球就有反应）。
- `窗口问=0` → 触摸根本没送进来，窗口那道闸没开对（回去看上一节的表）。
- `窗口问>0` 但 `落在球=0` → 触摸进来了，但没落在球上：球的位置 / 坐标系对不上。
- `落在球>0` 但 `真点击=0` → 触摸落到球上了，手势却没认出来（手势本身的问题）。

`最后：` 那行写着**最后停在哪一段**，还带上当时的坐标和球的矩形 —— 直接念出来就能定位。

### 球不出来 / 点不动怎么办

日志在 `/tmp/FloatingBall.log`（用手机上的 **TT 终端** `cat /tmp/FloatingBall.log` 就能看）。
每次点「启动悬浮球」都会重开一份日志。看它停在哪一行：

| 日志停在哪 | 说明 |
|---|---|
| 一条都没有 | App 都没走通，或者 spawn 就失败了 |
| `=== App 请求启动悬浮球 ===` 然后没了 | `posix_spawn` 失败，看紧跟其后的 `rc=`（rc 非 0 就是这步被拒） |
| 有 `HUD 进程启动` 但没 `窗口已建` | UIKit 没在 HUD 进程里支起来 |
| 有 `窗口已建` 但没 `球露面了` | 窗口没显示，或 SpringBoard 没接管 |
| 有 `球露面了` 但屏幕上没球 | 窗口特权/层级问题 |
| 球在但点不动 | 见下面「怎么判断触摸到底进没进来」两行日志 |

## 震动反馈（0.1.4；0.1.9 起强度可调；**0.1.12 起「时长」作废 + 球改成按下去就震**）

两个进程各有一份实现，共用**同一批设置键**：

| 谁 | 文件 |
|---|---|
| 屏幕上的球（HUD 进程） | `src/hud/BallRootViewController.mm`（`FBHapticPlay` + `- haptic:`） |
| App 界面 | `src/controllers/Haptics.swift`（`Haptics.fire`） |

三档震感，按「发生了什么」分：

| 档 | 手感 | 什么时候 |
|---|---|---|
| `tap` | 轻 | 识别到点击；球的拖动落位；在设置里选中某个选项 |
| `action` | 中 | 动作真的执行了：进/出移动模式、显示隐藏数字、开关悬浮球、复位位置 |
| `notice` | 两下 | 刷新信号 —— **只表示「交代出去了」，不表示成功**（这个 API 没有回执） |

开关：`HapticsEnabled`（Bool，**默认开**），在「启动」页。
（0.1.11 起「试一下震动」按钮没了 —— 打开开关那一下本身就会震，再放个按钮是重复。）

⚠️ **「没设过」必须按「开」处理**（Swift 侧 `BallSettings.bool(..., default: true)`，
HUD 侧判断 `NSNumber` 在不在）—— 否则老版本升上来会突然变成静音。

⚠️ 手机上「设置 → 声音与触感 → 系统触感反馈」关掉的话，我们全部没感觉。
那是系统总开关，绕不过去，所以 App 界面和交付邮件里都提示了这一条。

### 强度（0.1.9 起；「时长」0.1.12 已删）

| 键 | 范围 | 默认 | 怎么用 |
|---|---|---|---|
| `HapticIntensity` | 0.2~1.0 | 1.0 | `UIImpactFeedbackGenerator -impactOccurredWithIntensity:` |

**0.1.12：「时长」滑块去掉了**（用户 2026-10-17 定的：「时长就用系统默认的 40 毫秒，
再改的效果一般」）。0.1.9 的做法是「每 40ms 敲一下拼时长」（`pulses = round(ms/40)`，
1~8 下），技术背景是对的 —— iOS 不给第三方毫秒级的振动波形，想精确到毫秒得用
`CoreHaptics`，而它要求 App 在前台 + 有音频会话，HUD 那个常驻 root 进程里不靠谱 ——
但实测连敲拼出来的「长震」手感一般，直接证伪，所以整个删掉：
**一律就是系统默认那一下（约 40ms）**。`HapticDurationMs` 这个键两边都**不再读**
（不用清plist，留着也不影响）。

「通知那种两下」保留（`notice` = 两下 `medium` impact）—— 那是一个**信号**，
不是时长调节，受「强度」控制。

### 跟手性：按下去就得立刻震（0.1.7）

0.1.4~0.1.6 的写法有两个地方注定「慢半拍」，用户一按就感觉出来了：

1. **每次都新建一个生成器，然后 `prepare()` + 立刻震。**
   `prepare()` 是**异步**预热振动引擎的，跟 `impactOccurred()` 挤在同一个 tick 里，
   那一下引擎还是凉的 —— 表现就是延迟、跟手性差。
   → 改成**生成器常驻**（Swift 侧 `lightGen`/`mediumGen`；HUD 侧
   `sHapticLight`/`sHapticMedium`），界面一出现就 `warmUp()`，
   震完 0.8 秒再补一次 `prepare()` 保温；HUD 侧额外每 2 秒保温一次（球可能挂很久不被碰）。
2. **SwiftUI 的 `Button` 是「松开」才执行 action。**
   按键的反馈必须落在**按下去**那一刻，所以加了 `View.hapticOnPress(_:)`：
   用 `simultaneousGesture(DragGesture(minimumDistance: 0))` 抢到按下瞬间震一下，
   同时不影响按钮自己的点击（`simultaneousGesture` 两边都收）。
   已经用在：「试一下震动」「复位位置」「刷新」「换一张图片」。

另外 App 侧原来每震一次都要读盘（`BallSettings.bool` 会读 plist），现在开关值**缓存**在
`Haptics.cachedEnabled` 里，拨开关时同步更新，界面出现时重读一次。

> **0.1.12 落地：「球也按下去就震」**。挂点在 `HUDApp.mm` 的接管分支 ——
> 「起手落在球上」是整条链里**最早、最不依赖别人**的时刻，一喂出 `Began`
> 就调 `FBBallHapticTouchDown()`（桥接在 `BallRootViewController.mm` 里震一下 `tap`）。
> 手势那边认出来的单击/长按/落位还会有它自己的那一下 —— 那是「确认」，
> 这里是「迎客」，两层语义不冲突。

## 版本

| 版本 | 内容 |
|---|---|
| 0.1.0 | 验证版：球能浮在任何界面之上 + 能点 + 能拖吸边；轻点会打开「设置」并计数 +1；桌面图标长成系统小白点 |
| 0.1.1 | 球的外观可调：形状（小圆点 / 纯色 / 白点 / 自定义图片）+ 颜色 + 大小 + 不透明度；贴图改由 App 按设置画好给 HUD 显示 |
| 0.1.2 | 快捷列表（真的能用）+ 手势绑定 + 一键刷新信号（卡贴机用）；内置动作：刷新信号 / 打开悬浮球 / 打开快捷列表 / 移动球 / 显示隐藏数字 |
| 0.1.3 | **触摸改走「全局 HID 事件」那条路**（0.1.0~0.1.2 收不到任何触摸的真机结论）；「手势」那一栏每行右侧显示当前绑的是哪个动作 |
| 0.1.4 | **震动反馈**：点球 / 落位 / 执行动作各给一次震感（三档：轻 / 中 / 通知），「启动」页加开关（默认开）；App 里执行快捷项也有反馈 |
| 0.1.5 | **全局返回**：往系统注入一次「左缘往右划」（唯一一个能伤到系统的动作，见上面那节）；手势和「内置动作」里都能选 |
| 0.1.6 | **触摸自检**（「关于」页直接看①~⑤哪一段断了，见上）；修两个可能让球「被点穿」的点：`id<=0` 不再整条丢掉、HID 预热移出回调线程（回调里 dlopen 有卡死回调的风险） |
| 0.1.7 | **触摸来源换路**：真机自检证明老的 `BKSHIDEventRegisterEventCallback` 一条事件都收不到（`回调=0`），改用 `IOHIDEventSystemClient` 监视客户端（CreateWithType(1) + SetMatching(触摸屏) + RegisterEventCallback + ScheduleWithRunLoop）；两条路分开计数（`路A=` / `路B=`），谁先来谁生效。**同时修震动跟手性**：生成器常驻 + 提前预热，按钮改成「按下去就震」（见「震动反馈」一节） |
| 0.1.8 | **触摸改走真触摸**：逐条反汇编 TheBall 2.7 的 `HUDMainWindow`，发现它 `_ignoresHitTest = NO`（我们原来是 `YES`）——窗口重新参与命中测试，系统才会把落在球上的触摸送进这个进程。老路的 `_ignoresHitTest = YES` 是当年误判留下的（那时球上还没有手势识别器，触摸进来也没人接）。自检加一行「真触摸：窗口问= / 落在球= / 真点击=」，用来判断这条路通没通；真触摸一通就不再喂合成触摸（否则一次点击走两遍） |
| 0.1.9 | **内置动作库加「截屏」**（先走 `ScreenshotServices`，取不到才注入「音量加 + 电源」组合键，见上面那节）；**震动强度和时长可调**（`HapticIntensity` / `HapticDurationMs`，见「震动反馈」一节）；第二栏「快捷应用」**改名「快捷菜单」**（只动文案，`rawValue` 不变，老绑定不受影响；内置动作的名字改成现算，老列表也立刻显示新名字） |
| 0.1.10 | **快捷菜单那一栏改交互**：去掉右上角「编辑」，每行右边换成**拖动手柄**（三条横线），按住一行拖到哪就插到哪、松手才写盘 —— 点一下照样执行、左滑照样删（编辑模式的删除圈和左滑重复，且编辑模式下点一行不执行，所以整个不用它了）；**添加页新增一栏「添加」**（在「内置动作库」和「已安装的 App」中间，同一页显示）：**系统快捷指令**（填名字 → `shortcuts://run-shortcut?name=…`）和 **URL 协议**（内置微信扫一扫 / 支付宝扫一扫 / 微信收付款码，也能自己填一条，带内置图标）。URL 项也能绑到手势上；打开 URL 走新的 `FBOpenURL()`（三条路逐级退，见上） |
| 0.1.11 | **触摸：不再等那个永远不来的「按下」标志**（真机自检 30225 条事件里 `[rep isTouchDown]` 一次都没为真，而老逻辑只有它才接管）—— 改成「起手落在球上就算 `Began`」，抬起来自底层 IOHID 字段（`Touch=0 && Range=0`，连续两条）/ AX lift / 1.2 秒断档兜底；手指坐标「屏幕解释」「窗口解释」两种都试；`FBRealTouchWorks()` 收紧成「真点击 > 0」才停喂合成触摸（详见上面那节）。**启动开关不再卡**：`IsHUDEnabled()` 原来每次都要 `posix_spawn` 一整个二进制（`-check`）再 `waitpid`（一次 0.2~0.5 秒），关球还先睡 0.25 秒再等 —— 现在球把 pid 写到 `/tmp/FloatingBall.hud.pid`（App uid 501 与球 uid 0 都够得着），App 直接读 + `kill(pid,0)`（`EPERM` 也算在跑），关球 spawn 完即返回。界面去掉「状态」那一行（没生效时才显示一行红字）和「试一下震动」按钮（打开开关那一下本身就震，拖滑块也震）；自检加第三行「底层」 |
| 0.1.12 | **修「删了 App 球还在」**：球是 root 独立进程，删 App 只是拆 .app 目录，正在跑的进程没人管 —— 现在球每 3 秒确认一下自己所在 .app 目录还在不在，连续摸不到就 `exit(0)`（约 5~11 秒内球自己消失，pid 文件由 `atexit` 带走；连续 3 次而非 1 次是为了不被 TrollStore 覆盖安装时的短暂重建误杀）。**球按下去就震**：在「起手落在球上」喂 `Began` 的那一刻调 `FBBallHapticTouchDown()` 震一下（不依赖手势判不判得出来）。**「时长」滑块删除**（一律系统默认那一下 ≈40ms，`HapticDurationMs` 作废；`notice` 保留两下——那是信号不是时长）。**「原理来自」项目名变成蓝色可点**（SwiftUI `Link`，点开浏览器直达项目主页；链接全部用 GitHub API 核过） |
| 0.1.13 | **快捷菜单排序真机证伪后重做**：0.1.10 的 `.onDrag`+`.onDrop` 手柄能显示但顺序拖不动（当时没条件上真机验证）—— 整套删掉，换成 `ForEach.onMove`：SwiftUI List 自带「**长按一行拖着换位置**」，不需要编辑模式，三条横线手柄照旧当示意；换一次位置就写一次盘。**添加页搜索框改常驻顶行**：去掉 `.searchable`（那是塞在导航栏下的），改成 App 列表头部**固定一行**（放大镜 + 输入框 + 一键清空），往下滑列表它不动 |
