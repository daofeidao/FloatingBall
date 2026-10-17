//
//  Haptics.swift
//
//  App 这边的震动反馈。
//
//  ⚠️ 屏幕上那个球是**另一个进程**（root 的 HUD），它在 BallRootViewController.mm
//     里有一份等价实现 —— 两边用**同一个设置键** HapticsEnabled（默认开）。
//     改键名/默认值时两边必须一起改。
//
//  三种震感，按「发生了什么」分：
//    tap    识别到一次点击 / 选中了某个选项        —— 轻
//    action 动作真的执行了（开关、落位、移动模式）  —— 中
//    notice 「交代出去一件事」（刷新信号这种）      —— 通知那种两下
//
//  ⚠️ 手机上「设置 → 声音与触感 → 系统触感反馈」关掉的话，这里全部没感觉。
//     这是系统开关，我们绕不过去，所以界面上要提示用户去查。
//

import UIKit
import SwiftUI

enum Haptics {

    enum Kind {
        case tap
        case action
        case notice
    }

    // MARK: - 开关

    /// 开关（和球进程共用同一个键）。
    /// ⚠️ 缓存住：以前每震一次都要去读一遍 plist（BallSettings.bool 会读两次盘），
    ///    「按下去立刻震」这种要求下，这点延迟也得省掉。
    private static var cachedEnabled: Bool?

    static var enabled: Bool {
        if let v = cachedEnabled { return v }
        let v = BallSettings.bool("HapticsEnabled", default: true)
        cachedEnabled = v
        return v
    }

    /// 用户拨了开关 → 立刻更新缓存，别再读一遍盘。
    static func setEnabled(_ on: Bool) {
        cachedEnabled = on
    }

    /// 回前台 / 界面出现时从盘上重读一次（别的地方也可能改过）。
    static func refresh() {
        cachedEnabled = nil
        _ = enabled
    }

    // MARK: - 生成器：常驻 + 提前预热

    // 以前是「每次新建一个生成器 + prepare + 立刻震」—— 临时抱佛脚没用：
    // prepare() 是**异步**预热振动引擎的，跟 impactOccurred() 挤在同一个 tick 里，
    // 那一下照样是凉的（用户感觉就是「延迟几百毫秒、跟手性不够」）。
    // 正解：生成器常驻，提前 prepare 好，震完再补一次 prepare 保温。
    private static let lightGen  = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private static let noticeGen = UINotificationFeedbackGenerator()

    /// 提前把振动引擎叫醒。界面一出现就调，之后按下去才是「立刻」有反馈。
    static func warmUp() {
        guard enabled else { return }
        lightGen.prepare()
        mediumGen.prepare()
        noticeGen.prepare()
    }

    /// - Parameter force: 忽略开关，硬震一次。
    ///   只给「刚把开关打开」那一下用：那时候设置已经写成 true 了，
    ///   但用户需要**立刻**感觉到「开了」，不能等下一次点击。
    static func fire(_ kind: Kind, force: Bool = false) {
        guard force || enabled else { return }

        switch kind {
        case .tap:
            lightGen.impactOccurred()

        case .action:
            mediumGen.impactOccurred()

        case .notice:
            noticeGen.notificationOccurred(.success)
        }

        // 震完马上再预热一次，让引擎保持热的 —— 下一次按下去还是立刻有
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { warmUp() }
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
