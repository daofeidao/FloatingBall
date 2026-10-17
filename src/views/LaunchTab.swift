import SwiftUI
import UIKit

/// 球的样子。
///
/// ⚠️ 这里 rawValue 就是**贴图名**（layout/Applications/FloatingBall.app/*.png）。
///    设置里存的是贴图名本身，所以 App（Swift）和悬浮球进程（ObjC）两边
///    都不需要维护第二份「id -> 贴图」映射，加新样式只改这一个 enum + 画图脚本。
enum BallStyle: String, CaseIterable, Identifiable {
    case system = "BallDot"     // 默认：照手机自带的「辅助触控」小圆点
    case plain  = "BallPlain"   // 纯色极简
    case white  = "BallWhite"   // 白点（深色壁纸 / 夜间更显眼）

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "系统小圆点"
        case .plain:  return "纯色"
        case .white:  return "白点"
        }
    }

    var hint: String {
        switch self {
        case .system: return "和 iPhone 自带的辅助触控小圆点一样（默认）"
        case .plain:  return "一个干净的半透明圆"
        case .white:  return "深色壁纸、夜里更容易看见"
        }
    }

    var image: UIImage? { UIImage(named: rawValue) }

    static let fallback: BallStyle = .system
}

/// 第一栏：启动开关 + 球的基本设置
struct LaunchTab: View {

    @State private var enabled = false
    @State private var busy = false
    @State private var size = 56.0
    @State private var style: BallStyle = .fallback
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

                Section(header: Text("样子")) {
                    // 样式：一排缩略图，点一下就换
                    VStack(alignment: .leading, spacing: 8) {
                        Text("样式").font(.footnote).foregroundColor(.secondary)
                        HStack(spacing: 12) {
                            ForEach(BallStyle.allCases) { s in
                                Button {
                                    choose(s)
                                } label: {
                                    VStack(spacing: 6) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(Color(UIColor.secondarySystemBackground))
                                            if let img = s.image {
                                                Image(uiImage: img)
                                                    .resizable()
                                                    .frame(width: 40, height: 40)
                                            }
                                        }
                                        .frame(width: 60, height: 60)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(style == s ? Color.accentColor : Color(UIColor.separator),
                                                        lineWidth: style == s ? 2 : 0.5)
                                        )
                                        Text(s.title)
                                            .font(.caption2)
                                            .foregroundColor(style == s ? .accentColor : .secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Text(style.hint)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)

                    // 大小：范围放开到 32~100pt（球那边硬上限是 160）
                    VStack(alignment: .leading) {
                        HStack {
                            Text("大小")
                            Spacer()
                            Text("\(Int(size)) pt").foregroundColor(.secondary)
                        }
                        Slider(value: $size, in: 32...100, step: 2)
                            .onChange(of: size) { _ in saveSize() }
                    }

                    // 所见即所得：这里画的就是屏幕上球的真实大小
                    HStack {
                        Spacer()
                        if let img = style.image {
                            Image(uiImage: img)
                                .resizable()
                                .frame(width: size, height: size)
                        }
                        Spacer()
                    }
                    .frame(height: 108)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(10)

                    Button("复位位置") {
                        BallSettings.resetPosition()
                        BallSettings.notifyReload()
                    }
                }

                Section(header: Text("排障")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("日志文件").font(.footnote)
                        Text("/tmp/FloatingBall.log")
                            .font(.system(size: 12, design: .monospaced))
                        Text("球不出来时，用手机上的终端 cat 这个文件，能看到 HUD 进程走到哪一步了。")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
        style = BallStyle(rawValue: BallSettings.string("BallStyle", default: BallStyle.fallback.rawValue))
            ?? .fallback
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

    private func choose(_ s: BallStyle) {
        style = s
        BallSettings.set(s.rawValue, "BallStyle")
        BallSettings.notifyReload()
    }
}
