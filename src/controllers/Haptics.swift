//
//  Haptics.swift
//
//  App 这边的震动反馈。
//
//  ⚠️ 屏幕上那个球是**另一个进程**（root 的 HUD），它在 BallRootViewController.mm
//     里有一份等价实现 —— 两边用**同一批设置键**：
//       HapticsEnabled    开关（默认开）
//       HapticIntensity   强度 0.2~1.0（默认 1.0）   —— 0.1.9 起可调
//       HapticDurationMs  时长 10~300ms（默认 30）   —— 0.1.9 起可调
//     改键名 / 默认值 / 分段算法，两边必须一起改。
//
//  三种震感，按「发生了什么」分：
//    tap    识别到一次点击 / 选中了某个选项        —— 轻
//    action 动作真的执行了（开关、落位、移动模式）  —— 中
//    notice 「交代出去一件事」（刷新信号这种）      —— 两下
//
//  ⚠️ 手机上「设置 → 声音与触感 → 系统触感反馈」关掉的话，这里全部没感觉。
//     这是系统开关，我们绕不过去，所以界面上要提示用户去查。
//
//  ⚠️ 「时长」为什么是拼接出来的：iOS **不让第三方指定毫秒级的振动波形**
//     （Taptic 引擎「敲一下」的长度是系统定死的），想精确到毫秒得用 CoreHaptics，
//     而 CoreHaptics 要求 App 在前台 + 有音频会话 —— HUD 那个常驻 root 进程里不靠谱。
//     所以这里的「时长」= 连敲几下：每 pulseSpacingMs 毫秒一下，10~39ms = 1 下，
//     300ms ≈ 8 下。听感上就是「短促」到「连绵」。
//

import UIKit
import SwiftUI

enum Haptics {

    enum Kind {
        case tap
        case action
        case notice
    }

    // MARK: - 参数（⚠️ 与 HUD 侧 BallRootViewController.mm 保持一致）

    /// 每下之间隔多少毫秒
    static let pulseSpacingMs = 40
    /// 最多敲几下（≈320ms，够到 300ms 那档）
    static let maxPulses = 8

    static let minIntensity: Double = 0.2
    static let maxIntensity: Double = 1.0
    static let minDurationMs: Double = 10
    static let maxDurationMs: Double = 300
    /// 「时长」滑块的默认值（键没设过时用它，也是 HUD 侧的默认值）
    static let defaultDurationMs: Double = 30

    // MARK: - 开关 + 两个参数
    //
    // ⚠️ 三个都缓存住：以前每震一次都要去读一遍 plist（BallSettings 会读两次盘），
    //    「按下去立刻震」这种要求下，这点延迟也得省掉。
    //    App 里改滑块时用 setXxx() 直接更新缓存，球那边靠 Darwin 通知重读。

    private static var cachedEnabled: Bool?
    private static var cachedIntensity: Double?
    private static var cachedDurationMs: Double?

    static var enabled: Bool {
        if let v = cachedEnabled { return v }
        let v = BallSettings.bool("HapticsEnabled", default: true)
        cachedEnabled = v
        return v
    }

    /// 强度（0.2~1.0）
    static var intensity: Double {
        if let v = cachedIntensity { return v }
        let raw = BallSettings.double("HapticIntensity", default: maxIntensity)
        let v = min(max(raw, minIntensity), maxIntensity)
        cachedIntensity = v
        return v
    }

    /// 时长（毫秒）
    static var durationMs: Double {
        if let v = cachedDurationMs { return v }
        let raw = BallSettings.double("HapticDurationMs", default: defaultDurationMs)
        let v = min(max(raw, minDurationMs), maxDurationMs)
        cachedDurationMs = v
        return v
    }

    /// 时长换算成「敲几下」
    static var pulses: Int {
        let n = Int((durationMs / Double(pulseSpacingMs)).rounded())
        return min(max(n, 1), maxPulses)
    }

    /// 用户拨了开关 → 立刻更新缓存，别再读一遍盘。
    static func setEnabled(_ on: Bool) {
        cachedEnabled = on
    }

    static func setIntensity(_ value: Double) {
        cachedIntensity = min(max(value, minIntensity), maxIntensity)
    }

    static func setDurationMs(_ value: Double) {
        cachedDurationMs = min(max(value, minDurationMs), maxDurationMs)
    }

    /// 回前台 / 界面出现时从盘上重读一次（别的地方也可能改过）。
    static func refresh() {
        cachedEnabled = nil
        cachedIntensity = nil
        cachedDurationMs = nil
        _ = enabled
        _ = intensity
        _ = durationMs
    }

    // MARK: - 生成器：常驻 + 提前预热

    // 以前是「每次新建一个生成器 + prepare + 立刻震」—— 临时抱佛脚没用：
    // prepare() 是**异步**预热振动引擎的，跟 impactOccurred() 挤在同一个 tick 里，
    // 那一下照样是凉的（用户感觉就是「延迟几百毫秒、跟手性不够」）。
    // 正解：生成器常驻，提前 prepare 好，震完再补一次 prepare 保温。
    //
    // 强度要能调，所以三种震感都走 UIImpactFeedbackGenerator 的
    // impactOccurred(intensity:)（iOS 13+）；「通知那种两下」自己敲两下拼出来。
    private static let lightGen  = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGen = UIImpactFeedbackGenerator(style: .medium)

    /// 唤醒振动引擎（不看开关 —— fire 里要用）
    private static func prepareGenerators() {
        lightGen.prepare()
        mediumGen.prepare()
    }

    /// 提前把振动引擎叫醒。界面一出现就调，之后按下去才是「立刻」有反馈。
    /// 关着的时候不预热（省着点电，也免得用户以为「关了还震」）。
    static func warmUp() {
        guard enabled else { return }
        prepareGenerators()
    }

    /// 敲一下
    private static func pulse(_ kind: Kind) {
        let amount = CGFloat(intensity)
        if kind == .tap {
            lightGen.impactOccurred(intensity: amount)
        } else {
            mediumGen.impactOccurred(intensity: amount)
        }
    }

    /// - Parameter force: 忽略开关，硬震一次。
    ///   只给「刚把开关打开」那一下用：那时候设置已经写成 true 了，
    ///   但用户需要**立刻**感觉到「开了」，不能等下一次点击。
    static func fire(_ kind: Kind, force: Bool = false) {
        guard force || enabled else { return }
        prepareGenerators()

        // 「刷新信号」那种「交代出去一件事」= 两下；其余按设置敲
        let n = (kind == .notice) ? max(2, pulses) : max(1, pulses)

        for i in 0..<n {
            if i == 0 {
                pulse(kind)
                continue
            }
            let delay = Double(i * pulseSpacingMs) / 1000.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { pulse(kind) }
        }

        // 震完马上再预热一次，让引擎保持热的 —— 下一次按下去还是立刻有
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { prepareGenerators() }
    }
}

// MARK: - 「按下去就震」

/// SwiftUI 的 Button 是**松开**才执行 action，可按键的反馈必须落在按下去那一刻。
/// 这个修饰器用「同时识别」的拖拽手势（最小距离 0）抢到按下的瞬间：
/// 手指一碰上来就震，同时**不影响**按钮自己的点击（simultaneousGesture 两边都收）。
extension View {
    func hapticOnPress(_ kind: Haptics.Kind = .tap) -> some View {
        modifier(HapticOnPressModifier(kind: kind))
    }
}

struct HapticOnPressModifier: ViewModifier {
    let kind: Haptics.Kind
    @State private var fired = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !fired {
                        fired = true
                        Haptics.fire(kind)
                    }
                }
                .onEnded { _ in fired = false }
        )
    }
}
