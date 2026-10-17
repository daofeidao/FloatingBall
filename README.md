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

> 骨架沿用 [Helium](https://github.com/leminlimez/Helium)（GPL-3.0），
> 机制源头是 [TrollSpeed](https://github.com/Lessica/TrollSpeed) 与 [UIDaemon](https://github.com/limneos/UIDaemon)。

## 构建

本地（Windows）**不能编译**，只能靠 CI：

```
写代码 -> push -> GitHub Actions (macos-14 + Xcode 15.1 + theos) -> build/FloatingBall.tipa
```

打 tag（`v0.1.0`）会发布 Release 并附带 `FloatingBall.tipa`。
版本号唯一真源是 `layout/Applications/FloatingBall.app/Info.plist` 的 `CFBundleShortVersionString`。

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
4. **关了**：把开关关掉，球消失。

### ⚠️ 万一手机变得点不动了

**长按「电源 + 音量减」强制重启即可恢复。**

悬浮球进程**不是开机自启的守护进程**，重启就彻底没了，不需要卸载、不会留残留。

（为什么会有这个风险：球靠 `assistivetouchd` 那张工作证借了 SpringBoard 的一个层级。
如果 SpringBoard 把我们的窗口当成整屏的，就会吞掉整块屏幕的触摸。
所以代码里做了两层防护：窗口只开球那么大；根视图只让球本身吃触摸。）

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
| 球在但点不动 | 触摸没送到我们这个进程（要走备用路线：全局 HID 事件回调） |

## 版本

| 版本 | 内容 |
|---|---|
| 0.1.0 | 验证版：球能浮在任何界面之上 + 能点 + 能拖吸边；轻点会打开「设置」并计数 +1 |
