import SwiftUI

/// 第二栏：自定义快捷应用列表
/// v0.1 只放占位，说明 v0.2 要做成什么样。
struct AppsTab: View {
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("计划的形状")) {
                    Label("添加任意 App 或 URL 直达", systemImage: "plus.circle")
                    Label("拖动排序、左滑删除", systemImage: "arrow.up.arrow.down")
                    Label("每个条目指定用哪个手势触发", systemImage: "hand.tap")
                }

                Section(header: Text("动作类型")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("打开 App").font(.body)
                        Text("选一个已安装的 App，点球就打开它").font(.caption).foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("URL scheme 直达").font(.body)
                        Text("例如 weixin://scanqrcode 直接进微信扫一扫、alipays:// 进支付宝").font(.caption).foregroundColor(.secondary)
                    }
                }

                Section(footer: Text("v0.1 还没做这一栏。先确认球本身能用，再往这上面挂动作。")) {
                    EmptyView()
                }
            }
            .navigationTitle("快捷应用")
        }
    }
}
