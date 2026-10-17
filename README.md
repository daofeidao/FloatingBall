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
写代码 -> push -> GitHub Actions (macos-13 + Xcode 15.1 + theos) -> build/FloatingBall.tipa
```

打 tag（`v0.1.0`）会发布 Release 并附带 `FloatingBall.tipa`。
版本号唯一真源是 `layout/Applications/FloatingBall.app/Info.plist` 的 `CFBundleShortVersionString`。

改图标：`python scripts/make_icon.py`（自己画 PNG，不依赖 Pillow）。

## 怎么验证 v0.1

1. **装**：`FloatingBall.tipa` 传到手机 → 用巨魔（TrollStore）打开安装。
2. **开**：打开 App → 第一栏「启动」→ 把「启动悬浮球」打开。
   状态应变成「运行中」，屏幕上（右侧靠边、垂直居中）出现一个半透明圆球。
3. **验**：
   - **浮在最上层**：切到别的 App（微信、设置随便），球还在 → 这一条过了，整个形态就成立。
   - **点得到**：轻点球 → 计数 +1 并且打开「设置」；回 App 里看「轻点次数」。
   - **拖得动**：按住球拖到别的位置，松手会吸到左/右边缘；杀进程重开，位置还在。
   - 双击 = 计数清零；长按 = 显示/隐藏数字。
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
