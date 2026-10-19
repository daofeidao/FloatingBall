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
    @State private var tapCount = 0
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
    @State private var showPicker = false

    // ⚠️ 长文案一律提成 static let：以前 Section(footer:) 里现拼长字符串，
    //    CI 上的 Swift 编译器报过 `unable to type-check this expression in reasonable time`。
    private static let ballFooter = """
    震动反馈：点球、执行动作、球落位时会震一下（屏幕上的球和这个 App 都会震）。关掉之后哪儿都不震。

    · 强度 —— 0.2 到 1.0，拖滑块时当场就能感觉出来。
    · 时长固定是**系统默认那一下**（约 40ms），不给调了：iOS 不让第三方直接给毫秒级的振动波形（Taptic 引擎「敲一下」的长度是系统定死的），0.1.9 的「连敲几下拼时长」实测效果一般，所以去掉。

    0.1.31 起球上的振动改走**系统声音服务**（后台进程也能震）。⚠️ 0.1.32 起强度不再靠系统那个 `Intensity` 参数（iOS 15 真机上它不生效，20% 和 100% 区别听不出来），改成**用震动时长表达强弱**：20% ≈ 14ms、50% ≈ 24ms、100% = 40ms，而且**只震一下**（"刷新信号"也不敲两下了）。App 自己的按钮反馈仍是 Taptic 那种细腻震动。
    """

    private static let versionFooter = """
    0.1.35：**截屏不带球了**。系统截图抓的是整块屏幕，球挂在窗口上就一定会被拍进去，所以改成「先把球藏起来 → 0.3 秒后让系统截 → 1.2 秒后把球放回」；藏起来的这一小会儿，球那一片的触摸也会放过去，不会吃了你的手指。
    0.1.34：**「打开悬浮球」改成「关闭悬浮球」**。球就在屏幕上，这个菜单项拿来把球收掉更顺手：点了之后球淡出消失，等于回「启动」页把开关关一下。老列表里那条「打开悬浮球」会自动换成它（只换一次）；「打开悬浮球」本身还在动作库里，想加回来随时能加。
    0.1.33：**修「点截屏，球直接没了」**。球消失＝球的后台进程崩了：0.1.32 用的 ScreenshotServices 那个类其实是 SpringBoard 内部的东西，在别的进程里初始化会崩。现在改成让 SpringBoard 自己截（辅助触控「截屏」走的同一条系统通道），我们只发一条消息、不碰截图实现；万一这条路取不到，才退回「音量加 + 电源」按键注入。
    0.1.32：① 把手势区从「启动」页搬到「快捷菜单」页（菜单项列表下面）—— 这一页本来就是「菜单项 + 手势候选池」，放一起改更顺。绑定关系、默认值、存盘键都不变，老绑定照用。② 震动改短：**只震一下、最长 40ms**（"刷新信号"也不再敲两下）；强度改用**时长**区分（20% ≈ 14ms / 100% = 40ms），因为系统声音振动的 `Intensity` 参数在 iOS 15 上不生效。③ 点球开菜单更快：原来单击必须等双击判定失败（约 0.3 秒），现在**双击没绑动作时不再等**，点完立刻弹出。
    0.1.31：**修「震动强度设定没作用」—— 其实从来就没震过**：球是后台 root 进程，UIImpactFeedbackGenerator 的反馈只在前台有效、后台会被系统吞掉（所以强度滑块怎么拖都没用）。改成系统声音振动（AudioServicesPlaySystemSoundWithVibration），后台也能震、强度真的可调；每次震动前还从磁盘重读一次开关和强度。
    0.1.30：**0.1.29 的补强（直接发这版）** —— ① 菜单上的触摸不再缩球：原来菜单开着时整屏接管，每根手指落下都走 FBBallHapticTouchDown()，表现为「点哪里球都缩一下」的全局反馈；现在只有按在球上才缩。② 菜单行按下高亮；容器加触摸日志（按下/抬起/行号），点不动时能直接看出触摸有没有进来。
    0.1.29：**修「快捷菜单点不动」** —— 菜单项原来是 UIControl，靠 touchUpInside 触发；合成触摸的「抬起」坐标在本机经常丢（[rep location] 恒 (0,0)），UIControl 严格要求「抬起时还在这一行」，坐标一丢就判成在外面松手。改成：菜单容器自己收触摸（touchesBegan/Ended），按坐标算行号；HUD 侧把菜单上的触摸直接喂给容器，不依赖 hitTest；所有 Ended 统一喂在最后一次好坐标上。菜单行按下有高亮。
    0.1.25：修「拖球移不动 / 原地缩放」：`sLastFedPoint` 原来存的是**未经修正的坐标**（winPt），而「坐标不可信就沿用上一帧」靠它续命 —— 一旦某一帧坐标读不到（拖动中手指移出球、或这台设备 `[rep location]` 恒为 (0,0)），坏点就被永久记住，球钉在原地。改成存**真正喂出去的那个点**（feedPt），坏点只用一次。
    0.1.18：**整体照抄 TheBall**（用户定案）。反汇编对比后发现的根本差别：① 它的窗口是**全屏**的（`[UIScreen mainScreen].bounds`），球只是窗口里的一个子视图；我们以前把窗口做成「只有球那么大」，系统根本不会把触摸送进来。② 它的 `HUDMainWindow` 覆盖了 **9 个方法**，我们只有 3 个 —— 补上 `_isSecure`、`_shouldCreateContextAsSecure`、方向三个、以及「只把命中测试交给子视图、否则返回 nil」的 `hitTest`。③ 它的球**不用手势**，直接实现 `touchesBegan/Moved/Ended/Cancelled`，拿的是系统真触摸。这版起：球在全屏窗口里移动（拖动改球的位置，不再移动窗口），系统直接把触摸送进来；原先那套「从 HID 事件重建触摸」只留作后备（真点击一旦出现就自动停用）。
    0.1.17：① 修「只有第一下有用、后面点都不动」：抬起事件送不到时触点会一直攥着，后面的点击全被并成它的「移动」。现在三种情况都会先把上一轮结束再按新的处理 —— 事件断档 >0.15 秒、点跳了 >90pt（手指不会瞬移）、0.18 秒没新事件（原来 0.42 秒太长）。② 修「外观改了没反应」的**真正原因**：球每次写设置（点一下/拖完都会写）都把启动时读的旧快照整份写回，把 App 刚改的形状/颜色/大小/透明度盖掉了。现在只回写球自己负责的键（计数/位置/数字开关/落点），外观键以磁盘为准。③ 「关于」页诊断多一行「接管/喂球」累计数：接管不再涨而喂球在涨 = 触点卡住了。
    0.1.16：① 修「点一下之后球就卡死」：真机上「抬起」事件经常送不到，我们一直攥着假触点，后面的点击全被当成它的移动 —— 现在**断档 >0.15 秒就先补一个抬起**，另外 0.42 秒没新事件也会自己交还（比长按的 0.5 秒短，所以单击不会变成长按）。② 修「快速拖动时球跳到左上角」：空坐标事件 (0,0) 不再当成移动喂进去。③ 按下去球会**缩一下**（可见反馈）—— 真机确认 HUD 是后台进程，系统会把震动吞掉，光靠震动看不出「按到了」。④ 诊断多一行「结束=xxx」，能看出每次触摸是怎么结束的。⑤ 修「形状/颜色/大小/透明度改了没反应」：球每 2 秒比对一次外观文件的修改时间，变了就自己重新应用（不再只靠通知），「关于」页还加了**外观诊断**和一键「重新应用外观」。
    0.1.15：① 自喂测试证明「喂球这条路是通的」，所以问题只剩「这一下算不算按在球上」—— 这版把能拿到的坐标来源全用上（系统事件的点、每条手指路径自己的位置、底层子事件坐标的三种量纲），命中范围放宽到 10pt；起手也不再被「抬起」信号挡住。② 「关于」页新增**真实点球诊断**：点一下球，它会用一句人话告诉你「坐标在不在球上 / 有没有接管」，不用读数。③ 新增**盲喂**开关（默认关）：任何触摸都当点球（只震动计数、不执行动作），用来判断事件流里到底有没有真手指。④ 添加页搜索：一开始打字就只留「已安装的 App」一块（内置动作库/添加先收起来），搜出来的第一行就是 App 名字。
    0.1.14：① 触摸链找到根子了 —— 前几版读的是系统事件的**父事件**，手指状态（Touch / Range / 坐标）其实都在**子事件**上，所以「有手指」永远是 0、一次都没接管过球。这版会翻子事件去读（深读），并且不再把「读不到」当成「没手指」；起手落在球上也不再等系统那个从不出现的「按下」标志。② 「关于」页新增**自喂测试**：绕过 HID 检测，直接让球自己点一下 —— 球有反应＝喂球这条路通、毛病只在检测层；没反应＝喂球层不通。点一下就知道结论，不用你读数。
    0.1.13：① 快捷菜单的排序修好了 —— 长按一行（三条横线那头最顺手）往上拖，放到哪儿松手就定在哪儿，不用进什么编辑模式了（0.1.10 那条拖不动的老路整个删掉）。
    ② 添加页的搜索框：不再藏在导航栏里，改成 App 列表**头上的固定一行** —— 滑到列表里往上翻时它一直钉在最上面，随时能打字。
    0.1.12：① 震动只剩「强度」了 —— 「时长」滑块去掉（一律系统默认那一下，约 40 毫秒）。
    ② 「关于」页「原理来自」里那几个项目名变成**蓝色可点**了，点一下用浏览器打开它的项目主页。
    ③ 修了一个新报的 bug：把 App 删了，屏幕上的球还留着 —— 现在球每 3 秒确认一下「App 还在不在」，连续摸不到就自己消失（约 5~11 秒），不用重启了。
    ④ 球按下就震：以前要等手势判出来才震，手势一失灵按球就没一点动静；现在手一按上球就震，长按、动作执行仍然有各自的反馈。
    0.1.11：① 开关快了 —— 以前每次问「球在跑吗」都要在后台悄悄启动一整个程序，所以点了要等一两秒；现在球把自己的进程号写在 /tmp，App 读一下就够，松手即响应（顺手去掉了「状态」那一行，它没用）。
    ② 去掉「试一下震动」按钮：打开震动开关的那一下本身就会震，拖强度滑块也会当场震。
    ③ 触摸：真机自检显示「按下」这件事系统压根没告诉我们（30225 条事件里 0 次），老逻辑一直等它 —— 所以永远接不上。现在改成「手指第一次落在球上就算按下」。
    0.1.10：快捷菜单去掉右上角「编辑」（每行右边三条横线就是拖动手柄）；「添加」页中间多一栏「添加」，里面是「系统快捷指令」和「URL 协议」。
    点球没反应时，去「关于」页把「触摸自检」那几行念给我（0.1.11 起多了一行「底层」）。
    """

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("悬浮球"),
                        footer: Text(Self.ballFooter)) {
                    Toggle("启动悬浮球", isOn: Binding(
                        get: { enabled },
                        set: { want in setEnabled(want) }
                    ))

                    HStack {
                        Text("轻点次数")
                        Spacer()
                        Text("\(tapCount)").foregroundColor(.secondary)
                    }

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
                            .hapticOnPress(.tap)
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
                    .hapticOnPress(.action)
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

                Section(footer: Text(Self.versionFooter)) {
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

    // MARK: - 读写设置

    private func refresh() {
        enabled = IsHUDEnabledBridger()   // 0.1.11 起这条是「读 pid 文件 + kill(pid,0)」，微秒级
        tapCount = BallSettings.integer("TapCount", default: 0)
        hapticsOn = BallSettings.bool("HapticsEnabled", default: true)

        // 震动：重读强度 + 提前预热引擎（这样按下去才是立刻有反馈）
        // ⚠️ 0.1.12 起时长不可调（一律系统默认那一下），所以这里只重读强度。
        Haptics.refresh()
        hapticIntensity = Haptics.intensity
        Haptics.warmUp()

        shape = BallRenderer.loadShape()
        color = BallRenderer.loadColor()
        size = BallSettings.double("BallSize", default: 56)
        opacity = min(1.0, max(0.3, BallSettings.double("BallOpacity", default: 1.0)))
        customImage = BallRenderer.loadCustomImage()
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
