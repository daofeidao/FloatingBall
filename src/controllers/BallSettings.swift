//
//  BallSettings.swift
//
//  App（uid 501）和悬浮球进程（root）**读写同一个 plist 文件**。
//  路径必须和 hud-prefix.pch 里的 USER_DEFAULTS_PATH 一致。
//
//  改完设置后要发 Darwin 通知，球那边才知道要重读 —— 通知名与
//  hud-prefix.pch 的 NOTIFY_RELOAD_HUD 一致。
//

import Foundation

enum BallSettings {

    /// 与 hud-prefix.pch 的 USER_DEFAULTS_PATH 保持一致
    static let path = "/var/mobile/Library/Preferences/com.daofeidao.floatingball.plist"

    /// 与 hud-prefix.pch 的 NOTIFY_RELOAD_HUD 保持一致
    private static let reloadNotification = "com.daofeidao.notification.hud.reload"

    // MARK: - 读

    /// ⚠️ 0.1.19：原来这里写的是 `v == 0 ? fallback : v` —— **无法表达 0 这个合法值**，
    ///    用户真的存了 0 也会被静默换成默认值（今天恰好无害：
    ///    BallOpacity 被夹在 ≥0.3、HapticIntensity ≥0.2、BallSize 是 56，
    ///    但只要哪天加一个「允许 0」的滑块就会炸）。
    ///    改成和下面的 `bool()` 一样先问 `hasKey`。
    static func double(_ key: String, `default` fallback: Double) -> Double {
        guard hasKey(key) else { return fallback }
        return UserDefaults().double(forKey: key, forPath: path)
    }

    /// ⚠️ 0.1.19：原来 `fallback` 这个参数从头到尾**没被用过** ——
    ///    函数签名承诺「没设过时返回 fallback」，实际永远返回 0。
    ///    今天唯一调用点传的恰好是 `default: 0`，所以一直没暴露；
    ///    只要有人传一个非 0 的默认值就会静默失效。
    static func integer(_ key: String, `default` fallback: Int) -> Int {
        guard hasKey(key) else { return fallback }
        return UserDefaults().integer(forKey: key, forPath: path)
    }

    static func string(_ key: String, `default` fallback: String) -> String {
        let dict = UserDefaults().loadUserDefaults(forPath: path)
        return (dict[key] as? String) ?? fallback
    }

    /// 这个键到底存过没有。
    /// ⚠️ 为什么需要它：`integer()` 对「没设过」和「设成 0」返回的都是 0，
    ///    布尔型的键用 integer 读就分不清这两种情况。
    static func hasKey(_ key: String) -> Bool {
        let dict = UserDefaults().loadUserDefaults(forPath: path)
        return dict[key] != nil
    }

    static func bool(_ key: String, `default` fallback: Bool) -> Bool {
        guard hasKey(key) else { return fallback }
        return UserDefaults().bool(forKey: key, forPath: path)
    }

    // MARK: - 写

    static func set(_ value: Any?, _ key: String) {
        UserDefaults().setValue(value, forKey: key, forPath: path)
    }

    /// 复位位置：0.1 里用「负数」表示「没设过」，球那边会回到默认位置
    static func resetPosition() {
        set(-1, "BallX")
        set(-1, "BallY")
    }

    /// 告诉悬浮球进程：设置变了
    static func notifyReload() {
        FBPostNotify(reloadNotification)
    }
}
