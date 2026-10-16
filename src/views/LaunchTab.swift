import SwiftUI

/// 第一栏：启动开关 + 球的基本设置
struct LaunchTab: View {

    @State private var enabled = false
    @State private var busy = false
    @State private var size = 56.0
    @State private var status = "未检测"
    @State private var tapCount = 0

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("悬浮球")) {
                    Toggle("启动悬浮球", isOn: Binding(
                        get: { enabled },
                        set: { want in setEnabled(want) }
                    ))
                    .disabled(busy)

                    HStack {
                        Text("状态")
                        Spacer()
                        Text(status).foregroundColor(.secondary)
                    }
                    HStack {
                        Text("轻点次数")
                        Spacer()
                        Text("\(tapCount)").foregroundColor(.secondary)
                    }
                    Button("刷新") { refresh() }
                }

                Section(header: Text("外观")) {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("大小")
                            Spacer()
                            Text("\(Int(size)) pt").foregroundColor(.secondary)
                        }
                        Slider(value: $size, in: 40...88, step: 4)
                            .onChange(of: size) { _ in saveSize() }
                    }
                    Button("复位位置") {
                        BallSettings.resetPosition()
                        BallSettings.notifyReload()
                    }
                }

                Section(footer: Text("v0.1 是验证版，只验证一件事：悬浮球能不能浮在别的 App 上面，并且点得到、拖得动。轻点一次会打开「设置」并让计数 +1。")) {
                    EmptyView()
                }
            }
            .navigationTitle("悬浮球")
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        enabled = IsHUDEnabledBridger()
        status = enabled ? "运行中" : "未运行"
        size = BallSettings.double("BallSize", default: 56)
        tapCount = BallSettings.integer("TapCount", default: 0)
    }

    private func setEnabled(_ want: Bool) {
        busy = true
        enabled = want
        status = want ? "正在启动…" : "正在关闭…"
        SetHUDEnabledBridger(want)

        // 球进程起来/退出需要一点时间，稍后再确认一次真实状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let real = IsHUDEnabledBridger()
            enabled = real
            status = real ? "运行中" : (want ? "启动失败" : "未运行")
            busy = false
        }
    }

    private func saveSize() {
        BallSettings.set(size, "BallSize")
        BallSettings.notifyReload()
    }
}
