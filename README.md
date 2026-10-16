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

## 版本

| 版本 | 内容 |
|---|---|
| 0.1.0 | 验证版：球能浮在任何界面之上 + 能点 + 能拖吸边；轻点会打开「设置」并计数 +1 |
