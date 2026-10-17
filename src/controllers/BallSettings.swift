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

    static func double(_ key: String, `default` fallback: Double) -> Double {
        let v = UserDefaults().double(forKey: key, forPath: path)
        return v == 0 ? fallback : v
    }

    static func integer(_ key: String, `default` fallback: Int) -> Int {
        let v = UserDefaults().integer(forKey: key, forPath: path)
        return v
    }

    static func string(_ key: String, `default` fallback: String) -> String {
        let dict = UserDefaults().loadUserDefaults(forPath: path)
        return (dict[key] as? String) ?? fallback
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
