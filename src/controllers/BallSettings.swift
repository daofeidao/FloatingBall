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
    ///    BallOpacity 被夹在 ≥0.2（0.1.38 起，原来 ≥0.3）、HapticIntensity ≥0.2、BallSize 是 56，
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

    // MARK: - 0.1.44：设置文件本身的状态（用户 2026-10-29 踩的坑）

    /// 最近一次写入失败的原因（nil = 最近一次是成功的）。
    /// 由 `UserDefaults.setValue(_:forKey:forPath:)` 写入，「关于」页会显示出来。
    /// ⚠️ 以前这个错误只 `print` 到控制台，用户在界面上完全看不到 —— 表现出来就是
    ///    「改了没反应 / 恢复默认失效 / 删掉重装还是旧设置」。
    static var lastWriteError: String?

    /// 设置文件的人类可读描述：属主 / 权限 / 大小 / 最后修改时间。
    /// 属主是 `root` 就说明球进程把它写成了 root 所有 —— App 从此写不进去。
    static func fileInfo() -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return "文件不存在（一切按默认值走）"
        }
        let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
        let owner = (attrs[.ownerAccountName] as? String) ?? "?"
        let group = (attrs[.groupOwnerAccountName] as? String) ?? "?"
        let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm:ss"
        let permText = String(format: "%03o", perm)
        let ownedByRoot = (owner == "root")
        return "属主 \(owner):\(group) · 权限 \(permText) · \(size) 字节 · 改于 \(df.string(from: mtime))"
            + (ownedByRoot ? "  ⚠️ 属主是 root，App 写不进去 —— 点下面的「恢复出厂设置」" : "")
    }

    /// 恢复出厂设置：把整份设置清干净。
    ///
    /// 为什么不是「写一份默认值」：这个文件可能已经坏成 root 所有、App 根本写不动。
    /// 而**删文件**只要求目录可写（/var/mobile/Library/Preferences 本来就是 mobile 的），
    /// 所以删除比写入可靠。删完球进程手里还是旧快照，所以调用方要把它关掉再开
    /// （或者发 reload 通知让它重读 —— 这里直接关球最干净）。
    ///
    /// ⚠️ 会丢掉：球的位置 / 大小 / 颜色 / 自定义图标 / 快捷菜单 / 手势绑定。没有备份。
    @discardableResult
    static func factoryReset() -> Bool {
        // 1) 让 cfprefsd 忘掉这个域 —— 否则它手里的缓存可能又把文件写回来
        UserDefaults.standard.removePersistentDomain(forName: "com.daofeidao.floatingball")
        UserDefaults.standard.synchronize()

        // 2) 直接把文件删掉（目录可写就行，不要求文件属主是我们）
        var ok = true
        if FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                ok = false
                lastWriteError = "删除设置文件失败：\(error.localizedDescription)"
            }
        }
        return ok
    }
}
