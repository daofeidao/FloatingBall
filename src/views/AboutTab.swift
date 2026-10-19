import SwiftUI
import Combine

struct AboutTab: View {

    /// 只是用来戳一下刷新（值变了 body 就重算）
    @State private var probeTick = 0

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return v ?? "?"
    }

    /// 自检那两行的读法说明。
    /// ⚠️ 必须放在这里当成一个整体：直接写在 Section(footer:) 里拼接字符串，
    ///    Swift 类型检查会超时（CI 报 "unable to type-check this expression in reasonable time"）。
    private static let probeFooter = """
    第一行是「全局 HID 事件」那条链（0.1.3 起）：① 回调（路A = 老 BKS 回调，路B = 监视客户端）→ ② AX 转换 → ③ 手指路径 / 身份号 → ④ 起手在不在球上 → ⑤ 接管并喂给球。**接管**和**喂球**这两个数会一直涨 = 合成触摸这条路是通的。
    第二行是「真触摸 / 测试」：窗口问 = 系统问过窗口几次（0.1.19 起**长期是 0 才对** —— 我们刻意不让系统拿这个全屏窗口做命中测试）；落在球 = 其中落在球上的；真点击 = 球的手势一共触发了多少次；自喂测试 = 那个按钮做过几次。
    第三行「底层」（0.1.14 改）：深读 = 翻系统事件的**子事件**读手指状态（有手指 / 没手指 / 读不到）。
    第四行「最后」：最近一条事件的细节 —— 点 = 手指坐标，窗口点 = 换算后的坐标，球(窗口) = 球在窗口里的矩形，深读 / AX = 两套判据的原始值。
    哪个数不涨，断点就在哪。
    """

    /// 触摸自检：悬浮球进程（root 那个）把「HID 回调这条链子走到哪一步」写在 /tmp 里，
    /// App 直接读出来显示 —— 这样点球没反应时，不用开终端也能把这一行念出来。
    private var probeText: String {
        _ = probeTick
        return Self.readProbe()
    }

    private static func readProbe() -> String {
        let path = "/tmp/FloatingBall.probe"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "（读不到 /tmp/FloatingBall.probe）\n球进程可能没起来 —— 回「启动」页把开关关一下再打开。"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从自检文本里抠一个整数，例如 key="真点击" 时匹配 "真点击=3"。
    private static func probeInt(_ text: String, _ key: String) -> Int? {
        guard let r = text.range(of: key + "=") else { return nil }
        let digits = text[r.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    // ---- 外观诊断（0.1.16）----
    @State private var styleResult = ""

    private static func readStyle() -> [String: String] {
        guard let text = try? String(contentsOfFile: "/tmp/FloatingBall.style", encoding: .utf8) else {
            return [:]
        }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            if let idx = line.firstIndex(of: "=") {
                out[String(line[..<idx])] = String(line[line.index(after: idx)...])
            }
        }
        return out
    }

    private var styleDiag: [String: String] {
        _ = diagTick
        return Self.readStyle()
    }

    private func reapplyAppearance() {
        if let error = BallRenderer.regenerate() {
            styleResult = "重画失败：\(error)"
        } else {
            BallSettings.notifyReload()
            styleResult = "已重画贴图并让球重读。等 1~2 秒再看球有没有变；没变就把上面几行一起发我。"
        }
    }

    // ---- 自喂测试（0.1.14）----
    @State private var selfTestRunning = false
    @State private var selfTestResult = ""

    // ---- 截屏/全局返回的日志（0.1.23）----
    /// 这两个动作走的是「注入按键/触摸」，手机上看不见任何提示，
    /// 出问题只能靠日志。以前每次都得让用户开终端，太绕 ——
    /// 这里直接把球进程日志里相关的几行抠出来显示。
    private static func actionLogLines() -> [String] {
        guard let text = try? String(contentsOfFile: "/tmp/FloatingBall.log",
                                      encoding: .utf8) else { return [] }
        // ⚠️ 别用 text.split(separator: "\n") 再链 .map(String.init) ——
        // split 的 Element 在 Character / SubSequence 之间二义，链上 map 就报
        // ambiguous use of 'split(...)'（0.1.23 CI 实测挂在这儿）。
        // components(separatedBy:) 是 Foundation 的，直接给 [String]，没有二义。
        return Array(text.components(separatedBy: "\n")
            .filter { $0.contains("截屏") || $0.contains("全局返回") }
            .suffix(12))
    }

    private var actionLog: [String] {
        _ = actionLogTick
        return Self.actionLogLines()
    }

// ---- 真实点球诊断（0.1.15）----
    @State private var blindFeed = BallSettings.bool("BlindFeed", default: false)
    /// 0.1.26：`_ignoresHitTest` 的开关。默认 true = 吃掉触摸（不穿透），与 HUDMainWindow
    /// 运行时默认对齐（键不存在时返回 NO = 吃掉）。0.1.20~0.1.25 那几版默认关着是错误的。
    @State private var swallowTouch = BallSettings.bool("SwallowTouch", default: true)
    @State private var actionLogTick = 0
    @State private var diagTick = 0
    private let diagTicker = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    /// 每秒读一次诊断文件（diagTick 变了 body 才会重算）
    private var diag: [String: String] {
        _ = diagTick
        return Self.readDiag()
    }

    private static func readDiag() -> [String: String] {
        guard let text = try? String(contentsOfFile: "/tmp/FloatingBall.touchdiag", encoding: .utf8) else {
            return [:]
        }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            if let idx = line.firstIndex(of: "=") {
                out[String(line[..<idx])] = String(line[line.index(after: idx)...])
            }
        }
        return out
    }

    /// 把 diag 文件翻译成一句人话（不用用户读数）
    private static func verdict(_ d: [String: String]) -> String {
        guard !d.isEmpty else {
            return "还没有收到任何真实触摸事件 —— 先在屏幕上点球附近点几下，再回来看这里。"
        }
        let onBall = d["在球上"] == "1"
        let took = d["接管"] == "1"
        let raw = d["点"] ?? "?"
        let win = d["窗口点"] ?? "?"
        let ball = d["球窗口"] ?? "?"
        if onBall && took {
            let end = d["结束"] ?? "?"
            return "这一下被认成「按在球上」并且已经接管（球应该缩一下）。上一次触摸结束方式：\(end)。"
        }
        if onBall {
            return "坐标是对的（这点确实在球上），但**没接管** —— 挡住的是起手判据，不是坐标。"
        }
        return "坐标没落在球上：点=(\(raw)) 窗口点=(\(win))，球在窗口里是 (\(ball))。"
    }

    /// 绕过 HID 检测层，直接让球进程往球心喂一次点击。
    /// 结果只看一件事：球的单击手势有没有被认出来（自检里「真点击」+1）。
    private func runSelfTest() {
        let beforeTap = Self.probeInt(Self.readProbe(), "真点击") ?? 0
        let beforeRun = Self.probeInt(Self.readProbe(), "自喂测试") ?? 0
        selfTestRunning = true
        selfTestResult = "已请求球进程喂一次点击……"

        FBPostNotify("com.daofeidao.notification.hud.selftest.tap")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            let text = Self.readProbe()
            let afterTap = Self.probeInt(text, "真点击") ?? 0
            let afterRun = Self.probeInt(text, "自喂测试") ?? 0
            selfTestRunning = false
            probeTick += 1

            if afterRun == beforeRun {
                selfTestResult = "球进程没收到请求（可能没在跑）—— 回「启动」页把开关关一下再打开，再试。"
            } else if afterTap > beforeTap {
                selfTestResult = "✅ 成功：球的手势认出来了。说明**喂球这条路是通的**，问题只在检测层（HID 事件没被认成「按在球上」）——把下面第三行「最后」那句念给我就行。"
            } else {
                selfTestResult = "❌ 没反应：触摸喂进了 UIKit，但没交到球上。问题在**喂球层**（不是检测层）——这一条比任何读数都关键，直接告诉我这个结果。"
            }
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(version).foregroundColor(.secondary)
                    }
                    HStack {
                        Text("标识")
                        Spacer()
                        Text("com.daofeidao.floatingball").foregroundColor(.secondary)
                    }
                }

                Section(header: Text("真实点球诊断（0.1.15）"),
                        footer: Text("去屏幕上**点一下球**，然后回这里看结论 —— 不用读数。它显示的是球进程收到的最近一条真实触摸：点在哪儿、球在哪儿、有没有被认成「按在球上」。每秒自动刷新。")) {
                    Text(Self.verdict(diag))
                        .font(.footnote)

                    if !diag.isEmpty {
                        Text("深读=\(diag["深读"] ?? "?")   结束=\(diag["结束"] ?? "?")   接管/喂球=\(diag["累计接管"] ?? "?")/\(diag["累计喂球"] ?? "?")")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("截屏 / 全局返回 的执行记录（0.1.23）"),
                        footer: Text("这两个动作靠「往系统注入按键/触摸」实现，手机上看不见任何提示，出问题只能看日志。先在屏幕上试一次，再点下面的刷新。")) {
                    if actionLog.isEmpty {
                        Text("还没有相关记录 —— 先在屏幕上用一次「截屏」或「全局返回」。")
                            .font(.footnote)
                    } else {
                        ForEach(Array(actionLog.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption2, design: .monospaced))
                        }
                    }
                    Button("刷新记录") { actionLogTick += 1 }
                }

                Section(header: Text("穿透（0.1.20 新增，先关着）"),
                        footer: Text("打开后系统会拿我们这个窗口做命中测试，点在球上的那一下**理论上**就不漏给下面的 App 了（TheBall 就是这么做到的）。\n\n⚠️ 代价：万一系统仍然不把真触摸派发给球，整块屏幕会变成哑巴（什么都点不动）。真那样的话：长按「电源 + 音量减」强制重启，然后把这个开关关掉。\n\n球不需要重启，开关改完 1 秒内自动生效。")) {
                    Toggle("吃掉触摸（不穿透）", isOn: $swallowTouch)
                        .onChange(of: swallowTouch) { value in
                            BallSettings.set(value, "SwallowTouch")
                            BallSettings.notifyReload()
                        }
                }

                Section(header: Text("盲喂（验证用，平时关掉）"),
                        footer: Text("打开后：屏幕上**任何地方**的触摸都会被当成点球（只震动+计数，不执行绑定的动作）。\n用途：如果盲喂时球有反应 → 说明事件流里有真手指，只是坐标对不上；如果盲喂也没反应 → 说明事件流里根本没有手指，得换一条路。")) {
                    Toggle("盲喂：任何触摸都当点球", isOn: $blindFeed)
                        .onChange(of: blindFeed) { value in
                            BallSettings.set(value, "BlindFeed")
                            BallSettings.notifyReload()
                        }
                }

                Section(header: Text("外观诊断（0.1.16）"),
                        footer: Text("“图=包里的默认小圆点” 说明 App 画的贴图**没被球读到**（那就是写文件/通知那条链断了）；“图=App 画的贴图” 才是正常。点下面的按钮可以立刻重画一次并让球重读。")) {
                    if styleDiag.isEmpty {
                        Text("还没读到（球进程没起来？）").font(.footnote)
                    } else {
                        Text("球现在用的是：\(styleDiag["图"] ?? "?")；直径 \(styleDiag["球直径"] ?? "?")；透明度 \(styleDiag["球_alpha"] ?? "?")")
                            .font(.footnote)
                        Text("形状=\(styleDiag["形状"] ?? "?")  颜色=\(styleDiag["颜色"] ?? "?")  贴图时间=\(styleDiag["贴图时间"] ?? "?")")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Button("重新应用外观") { reapplyAppearance() }
                    if !styleResult.isEmpty {
                        Text(styleResult).font(.footnote).foregroundColor(.secondary)
                    }
                }

                Section(header: Text("自喂测试（先点这个）"),
                        footer: Text("它绕过 HID 检测，直接让球自己往球心喂一次「按下 + 抬起」。球会震一下 / 计数 +1 就是成功。这一步能把「检测层」和「喂球层」分开——点球没反应时先做这个，结论只有两种，都不用你读数。")) {
                    Button {
                        runSelfTest()
                    } label: {
                        HStack {
                            Text("让球自己点一下")
                            Spacer()
                            if selfTestRunning { ProgressView() }
                        }
                    }
                    .disabled(selfTestRunning)

                    if !selfTestResult.isEmpty {
                        Text(selfTestResult)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("触摸自检（点球没反应时看这里）"),
                        footer: Text(Self.probeFooter)) {
                    Text(probeText)
                        .font(.system(.caption, design: .monospaced))
                    Button("刷新") { probeTick += 1 }
                }

                Section(header: Text("这个 App 怎么工作")) {
                    Text("它启动后会把自己再拉起一次，这次以 root 身份常驻，并带着辅助触控（系统小白点）那一组系统权限，因此能把一个圆画在所有 App 之上。")
                        .font(.footnote)
                }

                Section(header: Text("原理来自"),
                        footer: Text("点项目名会用浏览器打开它的主页。本项目基于 Helium 的骨架，沿用 GPL-3.0 授权。")) {
                    credit("Lessica / TrollSpeed", "最早证明 TrollStore 免越狱能画全局悬浮窗",
                           "https://github.com/Lessica/TrollSpeed")
                    credit("limneos / UIDaemon", "「一个能画在 SpringBoard 之上的 iOS 守护进程」",
                           "https://github.com/limneos/UIDaemon")
                    credit("leminlimez / Helium", "本项目直接沿用了它的 HUD 骨架（GPL-3.0）",
                           "https://github.com/leminlimez/Helium")
                    credit("hhse / TheBall", "同类成品，本项目参考了它的交互设计",
                           "https://github.com/hhse/TheBall")
                }
            }
            .navigationTitle("关于")
            .onReceive(diagTicker) { _ in
                diagTick += 1
            }
        }
    }

    /// 一行「原理来自」：项目名是**蓝色可点的链接**，点了用系统浏览器打开项目主页。
    ///
    /// ⚠️ 用 `Link` 而不是 `Button` + `UIApplication.open`：
    ///    它就是「打开一个 URL」的语义，SwiftUI 自己会按 tint 染蓝、还支持长按预览；
    ///    而 `Button` 在 List 行里会多一层整行高亮，反而不好看。
    ///    http(s) 走系统默认处理器 = **Safari**；这里不需要 `FBOpenURL`（那是给 scheme 用的）。
    private func credit(_ title: String, _ detail: String, _ url: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let link = URL(string: url) {
                Link(destination: link) {
                    HStack(spacing: 5) {
                        Text(title)
                            .foregroundColor(.blue)
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                }
            } else {
                Text(title)
            }
            Text(detail).font(.caption).foregroundColor(.secondary)
        }
    }
}
