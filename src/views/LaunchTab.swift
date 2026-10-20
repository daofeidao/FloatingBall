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
    /// ⚠️ 只在**出问题**时才有值：开关没生效时在开关下面显示一行提示。
    /// 用户明确说过「未运行 / 运行中 / 正在关闭…」那一行是没用的东西 —— 常态一个字都不显示。
    @State private var trouble: String?
    @State private var hapticsOn = true

    // 震动参数（0.1.9 起强度可调；0.1.12 起时长去掉 —— 一律系统默认那一下 ≈40ms）
    @State private var hapticIntensity = Haptics.maxIntensity

    // 图标设置
    @State private var shape: BallShape = .dot
    @State private var color: UIColor = .black
    @State private var size = 56.0
    @State private var opacity = 1.0
    @State private var customImage: UIImage?

    /// 0.1.38：相册 + 「选一块」两层弹窗合成一个 enum 控制。
    /// 为什么：两层 sheet 连着弹（先关相册、立刻开裁剪）在 iOS 15 上会互相顶掉 ——
    /// 表现是「相册关了、裁剪页没出来」。用一个 item 驱动，中间留一点时间就稳了。
    @State private var iconSheet: IconSheet?
    /// 0.1.38：用过的自定义图（最多 3 张，最近在前）—— 换错了能换回去
    @State private var history: [UIImage] = []

    /// 0.1.38：闲置自动淡化 + 缩小（用户 2026-10-20 要求）
    @State private var idleDim = true
    @State private var idleSeconds = 5

    /// 图标那两层的弹窗（相册 / 选一块）
    private enum IconSheet: Identifiable {
        case picker
        case crop(UIImage)

        var id: String {
            switch self {
            case .picker: return "picker"
            case .crop:   return "crop"
            }
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("悬浮球")) {
                    Toggle("启动悬浮球", isOn: Binding(
                        get: { enabled },
                        set: { want in setEnabled(want) }
                    ))

                    if let trouble = trouble {
                        Text(trouble)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }

                    Toggle("震动反馈", isOn: Binding(
                        get: { hapticsOn },
                        set: { want in setHaptics(want) }
                    ))

                    // 强度（0.1.9 起可调）：关着的时候就别摆出来，少点干扰
                    // ⚠️ 0.1.12 起这里**只有强度**：时长去掉了（一律系统默认那一下 ≈40ms，
                    //    用户 2026-10-17 明确说的「时长就用系统默认的 40 毫秒，再改效果一般」）。
                    if hapticsOn {
                        VStack(alignment: .leading) {
                            HStack {
                                Text("强度")
                                Spacer()
                                Text("\(Int((hapticIntensity * 100).rounded()))%")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $hapticIntensity, in: 0.2...1.0, step: 0.05)
                                .onChange(of: hapticIntensity) { value in
                                    setHapticIntensity(value)
                                }
                        }
                    }

                    // ⚠️ 2026-10-17 用户明确：不要「试一下震动」这个按钮 ——
                    //    打开「震动反馈」开关的那一下**本身就会震**（见 setHaptics），
                    //    拖强度滑块时也会当场震，再放个按钮是重复的。
                    Button("刷新") { refresh() }.hapticOnPress(.tap)
                }

                Section(header: Text("图标")) {
                    // ---- 形状 ----
                    VStack(alignment: .leading, spacing: 8) {
                        Text("形状").font(.footnote).foregroundColor(.secondary)
                        HStack(spacing: 10) {
                            ForEach(BallShape.allCases) { s in
                                shapeTile(s)
                            }
                        }
                    }
                    .padding(.vertical, 2)

                    // ---- 自定义图片（0.1.38：选完先「选一块」，并留 3 张历史）----
                    if shape == .custom {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                if let img = customImage {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 44, height: 44)
                                        .clipShape(Circle())
                                }
                                Button(customImage == nil ? "从相册选一张图片…" : "换一张图片") {
                                    iconSheet = .picker
                                }
                                .hapticOnPress(.tap)
                            }

                            // 换图之前那几张留着（最多 3 张），点一下换回去
                            if !history.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("用过的（点一下换回去）")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    HStack(spacing: 10) {
                                        ForEach(history.indices, id: \.self) { i in
                                            Button {
                                                restoreHistory(i)
                                            } label: {
                                                Image(uiImage: history[i])
                                                    .resizable()
                                                    .scaledToFill()
                                                    .frame(width: 40, height: 40)
                                                    .clipShape(Circle())
                                                    .overlay(Circle()
                                                        .stroke(Color(UIColor.separator), lineWidth: 0.5))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                        }
                    }

                    // ---- 颜色 ----
                    VStack(alignment: .leading, spacing: 8) {
                        Text("颜色").font(.footnote).foregroundColor(.secondary)
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
                        // 0.1.38（用户 2026-10-20 要求）：最高 100%、最低 20%（原来下限是 30%）
                        Slider(value: $opacity, in: 0.2...1.0, step: 0.05)
                            // 同理：透明度是 HUD 那边给视图设 alpha，也不用重画
                            .onChange(of: opacity) { _ in saveAppearance(redraw: false) }
                    }

                    // ---- 闲置：自动淡化 + 缩小（0.1.38，用户要求）----
                    // 用户原话：「手势长时间没有动的话，应该变透明度最低缩到最小」
                    Toggle("闲置时淡化缩小", isOn: Binding(
                        get: { idleDim },
                        set: { want in setIdleDim(want) }
                    ))

                    if idleDim {
                        Picker("多久没动算闲置", selection: Binding(
                            get: { idleSeconds },
                            set: { v in setIdleSeconds(v) }
                        )) {
                            Text("3 秒").tag(3)
                            Text("5 秒").tag(5)
                            Text("10 秒").tag(10)
                            Text("30 秒").tag(30)
                        }
                        .pickerStyle(.menu)
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
                    .hapticOnPress(.action)
                }
            }
            .navigationTitle("悬浮球")
        }
        .onAppear { refresh() }
        // 0.1.38：相册 + 「选一块」两层合成一个 sheet（见 IconSheet 的说明）
        .sheet(item: $iconSheet) { sheet in
            switch sheet {
            case .picker:
                CustomImagePicker { image in
                    // 先收掉相册这层，再弹「选一块」—— 中间留一点时间，
                    // 不然两层 sheet 会互相顶掉（相册关了、裁剪页不出来）。
                    iconSheet = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        iconSheet = .crop(image)
                    }
                }
            case .crop(let source):
                IconCropView(source: source,
                             onCancel: { iconSheet = nil },
                             onDone: { cropped in
                                 applyCustomImage(cropped)
                                 iconSheet = nil
                             })
            }
        }
    }

    // MARK: - 小控件

    private var colorLocked: Bool { shape.isPreset || shape == .custom }

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
                iconSheet = .picker      // 选了「自定义」但还没图，直接把相册弹出来
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

    /// 震动开关。写进共享设置（球进程也读这个键），并通知它重读。
    private func setHaptics(_ want: Bool) {
        hapticsOn = want
        BallSettings.set(want, "HapticsEnabled")
        Haptics.setEnabled(want)            // 缓存跟着走，别再读盘
        BallSettings.notifyReload()
        // 打开的那一下硬震一次：用户需要立刻感觉到「开了」
        // （关的时候不震 —— 刚关掉还震会显得没生效）
        if want { Haptics.warmUp(); Haptics.fire(.action, force: true) }
    }

    /// 震动强度（0.2~1.0）：存共享设置 + 更新缓存 + 通知球进程重读，
    /// 并且**当场**用新强度震一下 —— 拖滑块时立刻能感觉出来。
    private func setHapticIntensity(_ value: Double) {
        let v = min(max(value, Haptics.minIntensity), Haptics.maxIntensity)
        hapticIntensity = v
        BallSettings.set(v, "HapticIntensity")
        Haptics.setIntensity(v)
        BallSettings.notifyReload()
        Haptics.fire(.action, force: true)
    }

    // MARK: - 自定义图（0.1.38：选一块 + 3 张历史）

    /// 裁剪页点了「用这张」：存下来 + 换到「自定义」+ 重画贴图。
    /// ⚠️ 存进去的是**裁好的那张**（正方形），球上按原样铺满 + 圆形裁切，
    ///    所以画面上看到的圆就是用户在裁剪页里对的那个圆。
    private func applyCustomImage(_ image: UIImage) {
        customImage = image
        if !BallRenderer.saveCustomImage(image) {
            trouble = "自定义图写不进 \(BallRenderer.customSourcePath)"
        }
        shape = .custom
        history = BallRenderer.loadCustomHistory()
        saveAppearance(redraw: true)
    }

    /// 点历史里的一张 → 换回那一张（当前这张会被收进历史，来回切不会丢）
    private func restoreHistory(_ index: Int) {
        guard BallRenderer.restoreCustomImage(fromHistory: index) else { return }
        customImage = BallRenderer.loadCustomImage()
        history = BallRenderer.loadCustomHistory()
        shape = .custom
        saveAppearance(redraw: true)
    }

    /// 闲置淡化缩小：开关
    private func setIdleDim(_ want: Bool) {
        idleDim = want
        BallSettings.set(want, "IdleDim")
        BallSettings.notifyReload()
    }

    /// 闲置淡化缩小：多久没动算闲置（秒）
    private func setIdleSeconds(_ value: Int) {
        idleSeconds = value
        BallSettings.set(value, "IdleDimSeconds")
        BallSettings.notifyReload()
    }

    // MARK: - 读写设置

    private func refresh() {
        enabled = IsHUDEnabledBridger()   // 0.1.11 起这条是「读 pid 文件 + kill(pid,0)」，微秒级
        hapticsOn = BallSettings.bool("HapticsEnabled", default: true)

        // 震动：重读强度 + 提前预热引擎（这样按下去才是立刻有反馈）
        // ⚠️ 0.1.12 起时长不可调（一律系统默认那一下），所以这里只重读强度。
        Haptics.refresh()
        hapticIntensity = Haptics.intensity
        Haptics.warmUp()

        shape = BallRenderer.loadShape()
        color = BallRenderer.loadColor()
        size = BallSettings.double("BallSize", default: 56)
        // 0.1.38：下限从 0.3 改成 0.2（用户要求最低 20%）
        opacity = min(1.0, max(0.2, BallSettings.double("BallOpacity", default: 1.0)))
        customImage = BallRenderer.loadCustomImage()
        history = BallRenderer.loadCustomHistory()
        // 0.1.38：闲置淡化缩小（没设过 = 开）
        idleDim = BallSettings.bool("IdleDim", default: true)
        idleSeconds = BallSettings.integer("IdleDimSeconds", default: 5)
    }

    /// 启动 / 关闭悬浮球。
    ///
    /// ⚠️ 2026-10-17 重写（用户原话：「打开和关闭速度非常慢」「状态那一行没必要」）：
    ///   · **乐观更新**：手指一松界面立刻动，不再等后台确认，也不再把开关 disable 掉
    ///     （以前 busy 期间开关是灰的，等 1.5 秒才恢复 —— 那种「卡住」的感觉就是它）；
    ///   · 慢的根因在 HUDHelper.mm / HUDApp.mm：原来每次问状态都要 spawn 一整个进程再 waitpid。
    ///     现在球把 pid 写在 /tmp（两边都够得着），App 直接读 + kill(pid,0)，微秒级；
    ///     关球也不再 sleep + waitpid。于是这里只需**便宜地**轮询几次看结果。
    ///   · 只有「没生效」时才在开关下面显示一行红字（常态一个字都不显示）。
    private func setEnabled(_ want: Bool) {
        enabled = want
        trouble = nil
        Haptics.fire(.action)             // 开 / 关都给一次触感回执
        SetHUDEnabledBridger(want)

        // 起球要等它自己写 pid 文件；退球要等 -exit 那个小进程干完活。都是几十~几百毫秒。
        var tries = 0
        func poll() {
            tries += 1
            let real = IsHUDEnabledBridger()
            if real == want {
                enabled = real
                return
            }
            if tries >= 12 {              // 12 × 0.15 ≈ 1.8 秒还没成 → 认为失败了
                enabled = real
                trouble = want
                    ? "球没起来。把开关关一下再打开；还不行就去「关于」页把自检念给我。"
                    : "球还在跑（没退干净）。再关一次；还不行就重启手机。"
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { poll() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { poll() }
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
            trouble = "贴图写入失败：\(error)"
            print("[FloatingBall] \(error)")
        }
        BallSettings.notifyReload()
    }
}
