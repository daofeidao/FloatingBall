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
    @State private var hapticsOn = true

    // 图标设置
    @State private var shape: BallShape = .dot
    @State private var color: UIColor = .black
    @State private var size = 56.0
    @State private var opacity = 1.0
    @State private var customImage: UIImage?
    @State private var showPicker = false

    // 手势绑定
    @State private var gestures: [String: String] = [:]
    @State private var shortcutItems: [ShortcutItem] = []

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("悬浮球"),
                        footer: Text("震动反馈：点球、执行动作、球落位时会震一下（屏幕上的球和这个 App 都会震）。关掉之后哪儿都不震。\n开着也没感觉的话，去「设置 → 声音与触感 → 系统触感反馈」看看是不是关的 —— 那个是系统总开关，绕不过去。")) {
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

                    Toggle("震动反馈", isOn: Binding(
                        get: { hapticsOn },
                        set: { want in setHaptics(want) }
                    ))

                    // 这按钮走的是同一个开关：关着就不震（不然用户会以为开关坏了）
                    Button("试一下震动") { Haptics.fire(.action) }

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
                        Haptics.fire(.action)
                    }
                }

                Section(header: Text("手势"),
                        footer: Text("每条手势各绑一个动作，右边就是当前绑的是哪个。默认：单击 = 打开「设置」，双击 = 什么都不做，长按 = 移动悬浮图标。拖动固定是移动球。球上的数字是「点到了」的回执。")) {
                    ForEach(ShortcutStore.gestureKeys) { entry in
                        gestureRow(title: entry.title, key: entry.id)
                    }
                    HStack {
                        Text("拖动")
                        Spacer()
                        Text("移动球，松手吸边").foregroundColor(.secondary)
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

                Section(footer: Text("0.1.6：球浮在任何界面之上；轻点 / 双击 / 长按各自绑一个动作（见上面「手势」一栏），拖动一直是移动球。\n点球没反应时，去「关于」页看「触摸自检」那一行。")) {
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

    /// 一条手势的绑定行：**右边直接显示现在绑的是哪个动作**（2026-10-17 要求），
    /// 点开是个菜单，里面是「内置动作 + 快捷列表里的 App」。
    private func gestureRow(title: String, key: String) -> some View {
        let current = gestures[key] ?? ShortcutStore.gestureTarget(key)

        // ⚠️ 只列「App」类的快捷项：内置动作下面已经单列了。
        //    （同一个 tag 在 Picker 里出现两次，SwiftUI 会分不清选中的是哪一个。）
        let appItems = shortcutItems.filter { $0.kind == .app }

        // 菜单里勾出当前这条：Menu 里的按钮不吃 Picker 的选中态，自己画个 ✓
        func marked(_ target: String) -> String { target == current ? "✓ " : "" }
        let noneMark = marked("")

        return Menu {
            Button("\(noneMark)未设置") { setGesture(key, "") }

            Divider()

            ForEach(ShortcutAction.allCases) { action in
                let target = "action:\(action.rawValue)"
                Button("\(marked(target))\(action.title)") { setGesture(key, target) }
            }

            if !appItems.isEmpty {
                Divider()
                ForEach(appItems) { item in
                    Button("\(marked(item.key))\(item.title)") { setGesture(key, item.key) }
                }
            }
        } label: {
            HStack {
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                Text(ShortcutStore.title(forKey: current, in: shortcutItems))
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
    }

    /// 改一条手势的绑定（存起来 + 通知球进程重读）
    private func setGesture(_ key: String, _ target: String) {
        gestures[key] = target
        ShortcutStore.setGestureTarget(key, target)
        Haptics.fire(.tap)
    }

    /// 震动开关。写进共享设置（球进程也读这个键），并通知它重读。
    private func setHaptics(_ want: Bool) {
        hapticsOn = want
        BallSettings.set(want, "HapticsEnabled")
        BallSettings.notifyReload()
        // 打开的那一下硬震一次：用户需要立刻感觉到「开了」
        // （关的时候不震 —— 刚关掉还震会显得没生效）
        if want { Haptics.fire(.action, force: true) }
    }

    // MARK: - 读写设置

    private func refresh() {
        enabled = IsHUDEnabledBridger()
        status = enabled ? "运行中" : "未运行"
        tapCount = BallSettings.integer("TapCount", default: 0)
        hapticsOn = BallSettings.bool("HapticsEnabled", default: true)

        shape = BallRenderer.loadShape()
        color = BallRenderer.loadColor()
        size = BallSettings.double("BallSize", default: 56)
        opacity = min(1.0, max(0.3, BallSettings.double("BallOpacity", default: 1.0)))
        customImage = BallRenderer.loadCustomImage()

        shortcutItems = ShortcutStore.load()
        for entry in ShortcutStore.gestureKeys {
            gestures[entry.id] = ShortcutStore.gestureTarget(entry.id)
        }
    }

    private func setEnabled(_ want: Bool) {
        busy = true
        enabled = want
        status = want ? "正在启动…" : "正在关闭…"
        Haptics.fire(.action)
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
