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
    第一行是「全局 HID 事件」那条链（0.1.3 起）：① 回调（路A = 老 BKS 回调，路B = 监视客户端）→ ② AX 转换 → ③ 手指路径 / 身份号 → ④ 在不在球上 → ⑤ 接管并喂给球。
    第二行是「真触摸」那条链（0.1.8 起，窗口直接收触摸）：窗口问 = 系统问过窗口几次；落在球 = 其中落在球上的；真点击 = 球的手势真的触发了。
    哪个数不涨，断点就在哪。
    """

    /// 触摸自检：悬浮球进程（root 那个）把「HID 回调这条链子走到哪一步」写在 /tmp 里，
    /// App 直接读出来显示 —— 这样点球没反应时，不用开终端也能把这一行念出来。
    private var probeText: String {
        _ = probeTick
        let path = "/tmp/FloatingBall.probe"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "（读不到 /tmp/FloatingBall.probe）\n球进程可能没起来 —— 回「启动」页把开关关一下再打开。"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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

                Section(header: Text("原理来自")) {
                    credit("Lessica / TrollSpeed", "最早证明 TrollStore 免越狱能画全局悬浮窗")
                    credit("limneos / UIDaemon", "「一个能画在 SpringBoard 之上的 iOS 守护进程」")
                    credit("leminlimez / Helium", "本项目直接沿用了它的 HUD 骨架（GPL-3.0）")
                    credit("hhse / TheBall", "同类成品，本项目参考了它的交互设计")
                }

                Section(footer: Text("本项目基于 Helium 的骨架，沿用 GPL-3.0 授权。")) {
                    EmptyView()
                }
            }
            .navigationTitle("关于")
        }
    }

    private func credit(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(detail).font(.caption).foregroundColor(.secondary)
        }
    }
}
