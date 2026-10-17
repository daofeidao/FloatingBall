import SwiftUI
import UIKit

/// 颜色快捷选项（点一下就换；想要别的用后面的系统取色器）
private let kColorPresets = ["#000000", "#FFFFFF", "#FF3B30", "#0A84FF", "#34C759", "#8E8E93"]

/// 第一栏：启动开关 + 图标设置
///
/// ⚠️ 这一栏的后半段就是用户说的「设置这个图标的界面」（2026-10-17 明确）：
///    形状 / 颜色 / 大小 / 不透明度 / 自定义图片 都在这里，改完球立刻变。
///    画图本身只在 BallRenderer 一处（预览和屏幕上的球共用同一份代码）。
struct LaunchTab: View {

    @State private var enabled = false
    @State private var busy = false
    @State private var status = "未检测"
    @State private var tapCount = 0

    // 图标设置
    @State private var shape: BallShape = .dot
    @State private var color: UIColor = .black
    @State private var size = 56.0
    @State private var opacity = 1.0
    @State private var customImage: UIImage?
    @State private var showPicker = false

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

                Section(header: Text("图标"),
                        footer: Text("这里设的就是屏幕上那个球。改完立刻生效，不用重启。桌面图标固定是第一个（小圆点）。")) {
                    // ---- 形状 ----
                    VStack(alignment: .leading, spacing: 8) {
                        Text("形状").font(.footnote).foregroundColor(.secondary)
                        HStack(spacing: 10) {
                            ForEach(BallShape.allCases) { s in
                                shapeTile(s)
                            }
                        }
                        Text(shape.hint).font(.caption2).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)

                    // ---- 自定义图片 ----
                    if shape == .custom {
                        HStack(spacing: 12) {
                            if let img = customImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 44, height: 44)
                                    .clipShape(Circle())
                            }
                            Button(customImage == nil ? "从相册选一张图片…" : "换一张图片") {
                                showPicker = true
                            }
                        }
                    }

                    // ---- 颜色 ----
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text("颜色").font(.footnote).foregroundColor(.secondary)
                            if let note = colorLockNote {
                                Text(note).font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        HStack(spacing: 8) {
                            ForEach(kColorPresets, id: \.self) { hex in
                                colorDot(hex)
                            }
                            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                                .labelsHidden()
                            Spacer(minLength: 0)
                        }
                        .opacity(colorLocked ? 0.35 : 1.0)
                        .disabled(colorLocked)
                    }

                    // ---- 大小 ----
                    VStack(alignment: .leading) {
                        HStack {
                            Text("大小")
                            Spacer()
                            Text("\(Int(size)) pt").foregroundColor(.secondary)
                        }
                        Slider(value: $size, in: 32...100, step: 2)
                            // 大小不用重画贴图：贴图里所有比例都是相对直径的，拉伸就行
                            .onChange(of: size) { _ in saveAppearance(redraw: false) }
                    }

                    // ---- 不透明度 ----
                    VStack(alignment: .leading) {
                        HStack {
                            Text("不透明度")
                            Spacer()
                            Text("\(Int((opacity * 100).rounded()))%").foregroundColor(.secondary)
                        }
                        Slider(value: $opacity, in: 0.3...1.0, step: 0.05)
                            // 同理：透明度是 HUD 那边给视图设 alpha，也不用重画
                            .onChange(of: opacity) { _ in saveAppearance(redraw: false) }
                    }

                    // ---- 预览：和屏幕上一样大（走的是同一个画图函数）----
                    HStack {
                        Spacer()
                        Image(uiImage: previewImage)
                            .resizable()
                            .frame(width: size, height: size)
                            .opacity(opacity)
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
        .sheet(isPresented: $showPicker) {
            CustomImagePicker { image in
                customImage = image
                _ = BallRenderer.saveCustomImage(image)
                shape = .custom
                saveAppearance(redraw: true)
            }
        }
    }

    // MARK: - 小控件

    private var colorLocked: Bool { shape.isPreset || shape == .custom }

    /// 颜色行被锁住时给一句解释（锁住的原因不一样，别混着说）
    private var colorLockNote: String? {
        switch shape {
        case .white:  return "（白点是预设，颜色固定）"
        case .custom: return "（自定义图片不用选颜色）"
        default:      return nil
        }
    }

    /// 预览图：和球用同一个画图函数，所以看到的就是实际效果
    private var previewImage: UIImage {
        BallRenderer.render(shape: shape,
                            color: color,
                            pixelSize: 256,
                            customImage: shape == .custom ? customImage : nil)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(color) },
            set: { newValue in
                color = UIColor(newValue)
                saveAppearance(redraw: true)
            }
        )
    }

    private func shapeTile(_ s: BallShape) -> some View {
        Button {
            shape = s
            if s == .custom && customImage == nil {
                showPicker = true      // 选了「自定义」但还没图，直接把相册弹出来
            } else {
                saveAppearance(redraw: true)
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(UIColor.secondarySystemBackground))
                    thumbnail(for: s)
                }
                .frame(width: 60, height: 60)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(shape == s ? Color.accentColor : Color(UIColor.separator),
                                lineWidth: shape == s ? 2 : 0.5)
                )
                Text(s.title)
                    .font(.caption2)
                    .foregroundColor(shape == s ? .accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func thumbnail(for s: BallShape) -> some View {
        if s == .custom {
            if let img = customImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
            }
        } else if let name = s.thumbnailName, let img = UIImage(named: name) {
            Image(uiImage: img).resizable().frame(width: 40, height: 40)
        }
    }

    private func colorDot(_ hex: String) -> some View {
        let paint = UIColor(hexString: hex) ?? .black
        let selected = !colorLocked && color.hexString.uppercased() == hex.uppercased()

        return Button {
            color = paint
            saveAppearance(redraw: true)
        } label: {
            ZStack {
                Circle().fill(Color(paint)).frame(width: 26, height: 26)
                Circle().stroke(Color(UIColor.separator), lineWidth: 0.5).frame(width: 26, height: 26)
                if selected {
                    Circle().stroke(Color.accentColor, lineWidth: 2).frame(width: 32, height: 32)
                }
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 读写设置

    private func refresh() {
        enabled = IsHUDEnabledBridger()
        status = enabled ? "运行中" : "未运行"
        tapCount = BallSettings.integer("TapCount", default: 0)

        shape = BallRenderer.loadShape()
        color = BallRenderer.loadColor()
        size = BallSettings.double("BallSize", default: 56)
        opacity = min(1.0, max(0.3, BallSettings.double("BallOpacity", default: 1.0)))
        customImage = BallRenderer.loadCustomImage()
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

    /// 把外观存进共享设置 + 让球进程重读。
    ///
    /// - Parameter redraw: 要不要重画贴图。
    ///   「形状 / 颜色 / 自定义图片」改了必须重画（贴图内容变了）；
    ///   「大小 / 不透明度」不用（HUD 那边拉伸 + 设 alpha 就行），
    ///   否则拖滑块时每动一下都要编码一次 PNG，界面会卡。
    private func saveAppearance(redraw: Bool) {
        BallSettings.set(shape.rawValue, "BallShape")
        BallSettings.set(color.hexString, "BallColor")
        BallSettings.set(size, "BallSize")
        BallSettings.set(opacity, "BallOpacity")

        if redraw, let error = BallRenderer.regenerate() {
            status = "贴图写入失败"
            print("[FloatingBall] \(error)")
        }
        BallSettings.notifyReload()
    }
}
