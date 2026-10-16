import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            LaunchTab()
                .tabItem { Label("启动", systemImage: "power") }
            AppsTab()
                .tabItem { Label("快捷应用", systemImage: "square.grid.2x2") }
            AboutTab()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
    }
}
