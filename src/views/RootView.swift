import SwiftUI
import UIKit

/// 谁想让 TabView 跳到哪一栏，都从这里走（现在只有「打开悬浮球 / 打开快捷菜单」两个动作用）。
final class TabRouter: ObservableObject {
    static let shared = TabRouter()
    @Published var tab: Int = 0
}

struct RootView: View {

    @ObservedObject private var router = TabRouter.shared

    var body: some View {
        TabView(selection: $router.tab) {
            LaunchTab()
                .tabItem { Label("启动", systemImage: "power") }
                .tag(0)
            AppsTab()
                .tabItem { Label("快捷菜单", systemImage: "square.grid.2x2") }
                .tag(1)
            AboutTab()
                .tabItem { Label("关于", systemImage: "info.circle") }
                .tag(2)
        }
        .onAppear { consumePendingTab() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            consumePendingTab()
        }
    }

    /// 悬浮球那边点了「打开悬浮球 / 打开快捷菜单」时，会往共享设置里写一个 PendingTab
    /// 再把 App 拉起来。App 起来（或从后台回到前台）就读这一下，然后清掉。
    ///
    /// 为什么要清掉：不然下次 App 从后台回来还会莫名其妙跳一次。
    private func consumePendingTab() {
        let want = BallSettings.string("PendingTab", default: "")
        guard !want.isEmpty else { return }

        TabRouter.shared.tab = (want == "apps") ? 1 : 0
        BallSettings.set("", "PendingTab")
    }
}
