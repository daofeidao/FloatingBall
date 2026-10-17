import SwiftUI

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
    第一行是「全局 HID 事件」那条链（0.1.3 起）：① 回调（路A = 老 BKS 回调，路B = 监视客户端）→ ② AX 转换 → ③ 手指路径 / 身份号 → ④ 起手在不在球上 → ⑤ 接管并喂给球。
    第二行是「真触摸 / 测试」：窗口问 = 系统问过窗口几次；落在球 = 其中落在球上的；真点击 = 球的手势真的触发了；自喂测试 = 那个按钮做过几次。
    第三行「底层」（0.1.14 改）：深读 = 翻系统事件的**子事件**读手指状态（有手指 / 没手指 / 读不到）。0.1.11 那版读的是父事件，永远是 0 —— 这就是之前「怎么点都没反应」的根子。
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

    // ---- 自喂测试（0.1.14）----
    @State private var selfTestRunning = false
    @State private var selfTestResult = ""

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
