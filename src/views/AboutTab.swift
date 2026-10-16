import SwiftUI

struct AboutTab: View {

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return v ?? "?"
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
