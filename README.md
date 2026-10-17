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

### 触摸是怎么送进来的（0.1.3 改的，重要）

⚠️ **只「显示」是不够的：SpringBoard 托管的那个窗口收不到触摸。**
0.1.0~0.1.2 一直假设「窗口能显示 → 窗口也能被点中」，真机把这个假设推翻了：

- 球**在每个界面都显示正常**（这一步一直是对的）；
- 但点球时球上的数字**一个都不涨** —— 说明系统根本没把触摸送进我们进程。
  把窗口的 `_ignoresHitTest` 改成 `NO`（表示「我要参与命中测试」）也一样收不到。

所以 0.1.3 换另一条路（源头同样是 TrollSpeed → Helium）：

1. 用 `BKSHIDEventRegisterEventCallback` 监听**全局 HID 事件**（有 assistivetouchd 权限才拿得到）；
2. 每个事件算一下「这一下是不是按在球上」（球在屏幕上的矩形往外放 6pt）；
3. 是，就把这个事件**喂成一次真正的 `UITouch`** 给球视图
   （`src/helpers/ts/TSEventFetcher.mm`，来源 Lessica/TrollSpeed）——
   之后 `UITapGestureRecognizer` / `UIPanGestureRecognizer` 这些就正常工作了。

两个副作用，都是有意的：

- 窗口的 `_ignoresHitTest` 因此改回 `YES`（和 Helium 一样）：**它绝不参与命中测试**，
  等于把「万一吞掉整屏触摸」的风险从根上去掉。尺寸仍然只有球那么大，算第二层保险。
- HID 回调**只能看、不能吃掉**事件：点在球上时，球下面那个 App **也会**收到这一下。
  这是这条路本身的限制（回调没有「吞掉事件」的能力），先接受。

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
   - **快捷列表**：「快捷应用」页点「添加」，加个 App 或内置动作；点那一行就执行。
   - **震动**：点球、球落位、执行动作时应各震一下；「启动」页的「震动反馈」开关能关掉它（关了就不震），
     开关旁边有「试一下震动」按钮可以当场试。
4. **关了**：把开关关掉，球消失。

## 快捷列表 / 手势 / 刷新信号（0.1.2）

**数据都在共享 plist 里**，App 和悬浮球进程读同一份：

| 键 | 内容 |
|---|---|
| `Shortcuts` | 快捷列表：`[{kind: app 或 action, id, title}]` |
| `GestureTap` / `GestureDoubleTap` / `GestureLongPress` | 每条手势绑一个 key：`app:bundleID` 或 `action:动作名` |
| `ShowLabel` | 球上的数字显示不显示 |
| `HapticsEnabled` | 震动反馈开关（默认开，见下面「震动反馈」一节） |
| `PendingTab` | HUD 让 App「起来后落在哪一栏」，App 读完就清掉 |

**存的是 key，不是下标** —— 快捷列表增删排序都不会把手势绑定搞乱。

内置动作：

| 动作 | 干什么 |
|---|---|
| 刷新信号 | 让基带重新注册、重新搜网（卡贴机没信号/假信号时用，见下） |
| 打开悬浮球 / 打开快捷列表 | 拉起 App 并落在对应那一栏 |
| 移动悬浮图标 | 球高亮进入「移动模式」，拖一下落位；点一下退出（防误触） |
| 显示/隐藏数字 | 球上那个数字 |
| 什么都不做 | —— |

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

### 还没做的两个动作

- **系统级返回**
- **截图**

这两个都要靠 HID 注入合成触摸/按键（`IOHIDEventSystemClientDispatchEvent` 那一套）。
配方不对的话，可能在屏幕上卡住一次触摸（得再点一下或重启才好），
而开发机是 Windows、编译只能靠 CI、真机只有一台且没有备份 —— 所以留到单独一轮做。

### ⚠️ 万一手机变得点不动了

**长按「电源 + 音量减」强制重启即可恢复。**

悬浮球进程**不是开机自启的守护进程**，重启就彻底没了，不需要卸载、不会留残留。

（为什么会有这个风险：球靠 `assistivetouchd` 那张工作证借了 SpringBoard 的一个层级。
如果 SpringBoard 把我们的窗口当成整屏的，就会吞掉整块屏幕的触摸。）

0.1.3 起这条风险基本被去掉了：那个全局窗口的 `_ignoresHitTest` 是 `YES`，
**不参与命中测试** —— 系统触摸不可能被它吃掉；尺寸仍然只有球那么大，算第二层保险。
触摸走的是「自己监听 HID 事件」那条路，就算那条路出错，也影响不到别人的触摸。

## 怎么判断触摸到底进没进来

日志里有两行专门为此写的（`/tmp/FloatingBall.log`）：

| 日志里有 | 说明 |
|---|---|
| `触摸回调已绑定球视图 frame=…` | 球视图注册上了（没有这行 = 注册没走到） |
| `触摸：按下落在球上（屏幕 x,y）→ 接管触点 n` | **按在球上的那一下进来了**（最关键的一行） |
| `触摸：触点 n 抬起/取消，交还` | 这一次触摸正常收尾 |

点球没有这行 → HID 回调那条路没生效（权限 / 系统版本），触摸根本没进来；

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

## 震动反馈（0.1.4）

两个进程各有一份实现，共用**同一个设置键**：

| 谁 | 文件 |
|---|---|
| 屏幕上的球（HUD 进程） | `src/hud/BallRootViewController.mm`（`FBHapticPlay` + `- haptic:`） |
| App 界面 | `src/controllers/Haptics.swift`（`Haptics.fire`） |

三档震感，按「发生了什么」分：

| 档 | 手感 | 什么时候 |
|---|---|---|
| `tap` | 轻 | 识别到点击；球的拖动落位；在设置里选中某个选项 |
| `action` | 中 | 动作真的执行了：进/出移动模式、显示隐藏数字、开关悬浮球、复位位置 |
| `notice` | 通知（两下） | 刷新信号 —— **只表示「交代出去了」，不表示成功**（这个 API 没有回执） |

开关：`HapticsEnabled`（Bool，**默认开**），在「启动」页。
开关旁边有个「试一下震动」按钮，走的是同一个开关（关着就不震，免得让人以为开关坏了）。

⚠️ **「没设过」必须按「开」处理**（Swift 侧 `BallSettings.bool(..., default: true)`，
HUD 侧判断 `NSNumber` 在不在）—— 否则老版本升上来会突然变成静音。

⚠️ 手机上「设置 → 声音与触感 → 系统触感反馈」关掉的话，我们全部没感觉。
那是系统总开关，绕不过去，所以 App 界面和交付邮件里都提示了这一条。

## 版本

| 版本 | 内容 |
|---|---|
| 0.1.0 | 验证版：球能浮在任何界面之上 + 能点 + 能拖吸边；轻点会打开「设置」并计数 +1；桌面图标长成系统小白点 |
| 0.1.1 | 球的外观可调：形状（小圆点 / 纯色 / 白点 / 自定义图片）+ 颜色 + 大小 + 不透明度；贴图改由 App 按设置画好给 HUD 显示 |
| 0.1.2 | 快捷列表（真的能用）+ 手势绑定 + 一键刷新信号（卡贴机用）；内置动作：刷新信号 / 打开悬浮球 / 打开快捷列表 / 移动球 / 显示隐藏数字 |
| 0.1.3 | **触摸改走「全局 HID 事件」那条路**（0.1.0~0.1.2 收不到任何触摸的真机结论）；「手势」那一栏每行右侧显示当前绑的是哪个动作 |
| 0.1.4 | **震动反馈**：点球 / 落位 / 执行动作各给一次震感（三档：轻 / 中 / 通知），「启动」页加开关（默认开）；App 里执行快捷项也有反馈 |
