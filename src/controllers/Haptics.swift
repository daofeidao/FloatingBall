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

enum Haptics {

    enum Kind {
        case tap
        case action
        case notice
    }

    /// 开关（和球进程共用同一个键）
    static var enabled: Bool {
        BallSettings.bool("HapticsEnabled", default: true)
    }

    /// - Parameter force: 忽略开关，硬震一次。
    ///   只给「刚把开关打开」那一下用：那时候设置已经写成 true 了，
    ///   但用户需要**立刻**感觉到「开了」，不能等下一次点击。
    static func fire(_ kind: Kind, force: Bool = false) {
        guard force || enabled else { return }

        switch kind {
        case .tap:
            let g = UIImpactFeedbackGenerator(style: .light)
            g.prepare()
            g.impactOccurred()

        case .action:
            let g = UIImpactFeedbackGenerator(style: .medium)
            g.prepare()
            g.impactOccurred()

        case .notice:
            let g = UINotificationFeedbackGenerator()
            g.prepare()
            g.notificationOccurred(.success)
        }
    }
}
