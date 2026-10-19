//
//  ShortcutStore.swift
//
//  快捷项目 = 「一键刷新信号」这类东西的骨架。
//
//  三种：
//    ① 打开某个 App（kind = app，id = bundleID）
//    ② 内置动作（kind = action，id = ShortcutAction）—— 刷新信号、截屏、移动球、打开菜单…
//    ③ URL 协议 / 系统快捷指令（kind = url，id = 一整条 URL）——
//       微信扫一扫 weixin://scanqrcode、系统快捷指令 shortcuts://run-shortcut?name=…
//
//  存在 App 和悬浮球进程共享的那个 plist 里，两边读同一份（见 hud-prefix.pch）。
//  手势绑定里存的是 key（"app:xxx" / "action:xxx" / "url:xxx"），不存下标 ——
//  这样快捷列表增删排序都不会把绑定搞乱。
//

import Foundation

// MARK: - 内置动作

enum ShortcutAction: String, CaseIterable, Identifiable {
    case refreshSignal      // 刷新蜂窝信号
    case goBack             // 全局返回（往系统注入一次「左缘往右划」）
    case screenshot         // 截屏（优先走系统截图服务，不行才注入「音量加 + 电源」）
    case openMainApp        // 打开悬浮球主界面
    case quitBall           // 关闭悬浮球（把屏幕上的球收掉）
    case openAppList        // 打开快捷菜单（App 第 2 栏）
    case moveBall           // 移动悬浮图标
    case toggleLabel        // 显示 / 隐藏球上的数字
    case none               // 什么都不做

    var id: String { rawValue }

    // ⚠️ 下面这些文案是**显示用**的：rawValue 一旦定了就不能改（用户的快捷列表和
    //    手势绑定里存的就是它，改了老绑定全失效）。所以 2026-10-17 改名的
    //    「快捷应用 → 快捷菜单」只动文案，不动 rawValue。
    var title: String {
        switch self {
        case .refreshSignal: return "刷新信号"
        case .goBack:        return "全局返回"
        case .screenshot:    return "截屏"
        case .openMainApp:   return "打开悬浮球"
        case .quitBall:      return "关闭悬浮球"
        case .openAppList:   return "打开快捷菜单"
        case .moveBall:      return "移动悬浮图标"
        case .toggleLabel:   return "显示/隐藏数字"
        case .none:          return "什么都不做"
        }
    }

    /// 列表里那行小字
    var detail: String {
        switch self {
        case .refreshSignal: return "卡贴机没信号 / 假信号时点一下，让基带重新搜网"
        case .goBack:        return "⚠️ 等于按「上一页」：往系统注入一次左缘右划。万一界面卡住点不动 → 强制重启即可恢复"
        case .screenshot:    return "让系统截当前屏幕，图进「相册 → 截屏」。走的是辅助触控「截屏」同一条系统通道；万一不通才注入「音量加 + 电源」"
        case .openMainApp:   return "回到悬浮球 App 的「启动」页"
        case .quitBall:      return "把屏幕上的球收掉（等于回 App 把「启动悬浮球」关一下），球没了这个菜单也就没了"
        case .openAppList:   return "回到悬浮球 App 的「快捷菜单」栏"
        case .moveBall:      return "球变成可拖动状态，拖着放到顺手的位置"
        case .toggleLabel:   return "球上那个数字显示 / 不显示"
        case .none:          return "不做事"
        }
    }

    var symbol: String {
        switch self {
        case .refreshSignal: return "antenna.radiowaves.left.and.right"
        case .goBack:        return "arrow.uturn.backward"
        case .screenshot:    return "camera.viewfinder"
        case .openMainApp:   return "app.badge"
        case .quitBall:      return "power"
        case .openAppList:   return "square.grid.2x2"
        case .moveBall:      return "hand.draw"
        case .toggleLabel:   return "textformat.123"
        case .none:          return "slash.circle"
        }
    }
}

// MARK: - 内置 URL（URL 协议 / 系统快捷指令）

/// 「添加」页「URL 协议」那一栏的内置条目。
///
/// ⚠️ 每条 URL 都是**查证过**的（2026-10-17，见 MEMORY §七）：
///   · 微信扫一扫   `weixin://scanqrcode`
///   · 微信收付款码 `weixin://widget/pay`
///   · 支付宝扫一扫 `alipayqr://platformapi/startapp?saId=10000007`
///   · 系统快捷指令 `shortcuts://run-shortcut?name=<名字>`（Apple 官方文档的 scheme）
struct BuiltinURL: Identifiable {
    let title: String       // 显示名
    let url: String         // 真正打开的那条 URL
    let icon: String        // SF Symbol（「简单的图标」：按功能给，不模仿各家的 Logo）

    var id: String { url }

    var item: ShortcutItem {
        ShortcutItem(kind: .url, id: url, title: title, icon: icon)
    }
}

enum BuiltinURLs {

    /// 「URL 协议」栏里默认内置的三条
    static let presets: [BuiltinURL] = [
        BuiltinURL(title: "微信扫一扫",   url: "weixin://scanqrcode",        icon: "qrcode.viewfinder"),
        BuiltinURL(title: "支付宝扫一扫", url: "alipayqr://platformapi/startapp?saId=10000007",
                   icon: "qrcode.viewfinder"),
        BuiltinURL(title: "微信收付款码", url: "weixin://widget/pay",        icon: "creditcard"),
    ]

    /// 系统快捷指令的图标（那一行不是「点一下就加」，是在同一页填名字）
    static let shortcutIcon = "sparkles"

    /// 把「快捷指令」App 里的指令名字拼成 URL（名字要 URL 编码）
    ///
    /// ⚠️ 0.1.19：原来用 `.urlQueryAllowed`。那个字符集是给**整条 query 串**用的，
    /// 它**包含** sub-delims —— `&` `;` `=` `+` `,` `$`，还包括 `/` `?`。
    /// 一条叫「天气 & 提醒」的快捷指令会生成
    /// `shortcuts://run-shortcut?name=天气%20&%20提醒`，对面解析成 `name=天气 `
    /// 并把 `提醒` 当成另一个参数丢掉；名字里的 `+` 在 form 解码下还会变成空格。
    /// 中文快捷指令名里出现「&」并不罕见。
    /// 现在明确把分隔符从允许集里扣掉。
    static func shortcutURL(name: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        return "shortcuts://run-shortcut?name=\(encoded)"
    }
}

// MARK: - 快捷项目

struct ShortcutItem: Identifiable, Equatable {
    enum Kind: String {
        case app    = "app"
        case action = "action"
        case url    = "url"     // URL 协议 / 系统快捷指令（id 就是一整条 URL）
    }

    var kind: Kind
    var id: String          // app -> bundleID；action -> ShortcutAction.rawValue；url -> 整条 URL
    var title: String
    /// 内置图标（SF Symbol 名）。nil = 按 kind 猜一个
    var icon: String? = nil

    /// 手势绑定 / 去重用的唯一 key
    var key: String { "\(kind.rawValue):\(id)" }

    /// 内置动作（用来判断它能不能在 App 里直接执行）
    var action: ShortcutAction? {
        kind == .action ? ShortcutAction(rawValue: id) : nil
    }

    var symbol: String {
        if let icon = icon { return icon }
        switch kind {
        case .app:    return "app"
        case .action: return action?.symbol ?? "questionmark"
        case .url:    return "link"
        }
    }

    /// 显示用的名字。
    /// ⚠️ 内置动作**永远现算**（`action.title`），不用存在列表里的那份 ——
    ///    这样改文案（比如 0.1.9 的「快捷应用 → 快捷菜单」）对**已经存过的老列表**也立刻生效。
    var displayTitle: String {
        if let action = action { return action.title }
        return title
    }

    /// 列表里那行小字：内置动作看它的 detail，其它就把 id 摆出来（App 就是 bundleID、URL 就是那条 URL）
    var detail: String {
        action?.detail ?? id
    }

    static func make(action: ShortcutAction) -> ShortcutItem {
        ShortcutItem(kind: .action, id: action.rawValue, title: action.title)
    }
}

// MARK: - 读写

enum ShortcutStore {

    static let shortcutsKey = "Shortcuts"

    /// 第一次打开时给三条，让用户知道这栏是干嘛的
    static let defaults: [ShortcutItem] = [
        .make(action: .refreshSignal),
        .make(action: .openAppList),
        ShortcutItem(kind: .app, id: "com.apple.Preferences", title: "设置"),
    ]

    /// 手势槽位
    ///
    /// ⚠️ 这里必须是结构体，不能图省事写成元组数组：
    ///    `ForEach(..., id: \.key)` 需要对 key 取 keyPath，
    ///    而 Swift 的 keyPath **不能指向元组成员**，写成元组编译不过。
    struct GestureSlot: Identifiable {
        let id: String          // 就是设置里的键名
        let title: String       // 「单击」…
        let note: String        // 默认绑的是什么，写在页脚附近
    }

    /// 手势 -> 设置键（键名和 HUD 那边读的完全一致）
    static let gestureKeys: [GestureSlot] = [
        GestureSlot(id: "GestureTap",       title: "单击", note: "默认打开「设置」"),
        GestureSlot(id: "GestureDoubleTap", title: "双击", note: "默认什么都不做"),
        GestureSlot(id: "GestureLongPress", title: "长按", note: "默认进入移动模式"),
    ]

    static let gestureDefaults: [String: String] = [
        "GestureTap":       "app:com.apple.Preferences",
        "GestureDoubleTap": "action:none",
        "GestureLongPress": "action:moveBall",
    ]

    /// 0.1.34：「打开悬浮球 → 关闭悬浮球」的一次性迁移标记。
    ///
    /// 用户 2026-10-19 提的：球就在屏幕上，这个菜单项拿来「把球收掉」比「打开 App」有用。
    /// 只迁一次 —— 之后用户自己再从动作库里把「打开悬浮球」加回来，就不再动它。
    static let quitBallMigratedKey = "ShortcutsQuitBallMigrated"

    static func load() -> [ShortcutItem] {
        let dict = UserDefaults().loadUserDefaults(forPath: BallSettings.path)
        var items: [ShortcutItem] = defaults
        if let raw = dict[shortcutsKey] as? [[String: Any]] {
            let parsed: [ShortcutItem] = raw.compactMap { row in
                guard let kindRaw = row["kind"] as? String,
                      let kind = ShortcutItem.Kind(rawValue: kindRaw),
                      let id = row["id"] as? String,
                      let title = row["title"] as? String
                else { return nil }
                return ShortcutItem(kind: kind, id: id, title: title,
                                    icon: row["icon"] as? String)
            }
            if !parsed.isEmpty { items = parsed }
        }

        // 0.1.34：老列表里的「打开悬浮球」换成「关闭悬浮球」（只做一次）
        if !BallSettings.bool(quitBallMigratedKey, default: false) {
            let converted = items.map { item -> ShortcutItem in
                (item.kind == .action && item.id == "openMainApp")
                    ? .make(action: .quitBall)
                    : item
            }
            if converted.map(\.key) != items.map(\.key) {
                save(converted)
            }
            BallSettings.set(true, quitBallMigratedKey)
            items = converted
        }

        return items
    }

    static func save(_ items: [ShortcutItem]) {
        let raw: [[String: Any]] = items.map { item in
            // ⚠️ 「url」这类老版本没有的字段是**可选**的：老列表读进来 icon 是 nil，
            //    存回去就不写这个键（不会凭空多出一堆空字段）。
            var row: [String: Any] = ["kind": item.kind.rawValue,
                                      "id": item.id,
                                      "title": item.title]
            if let icon = item.icon { row["icon"] = icon }
            return row
        }
        BallSettings.set(raw, shortcutsKey)
    }

    // MARK: 手势绑定

    static func gestureTarget(_ key: String) -> String {
        let current = BallSettings.string(key, default: "")
        if !current.isEmpty { return current }
        return gestureDefaults[key] ?? ""
    }

    static func setGestureTarget(_ key: String, _ target: String) {
        BallSettings.set(target, key)
        BallSettings.notifyReload()
    }

    /// 把一个 key 变成能显示的名字（找不到就原样返回，方便排障）
    static func title(forKey key: String, in items: [ShortcutItem]) -> String {
        if key.isEmpty { return "未设置" }
        if let item = items.first(where: { $0.key == key }) { return item.displayTitle }
        if key.hasPrefix("action:"),
           let action = ShortcutAction(rawValue: String(key.dropFirst("action:".count))) {
            return action.title
        }
        if key.hasPrefix("app:") {
            return String(key.dropFirst("app:".count))
        }
        return key
    }
}
