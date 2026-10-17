//
//  ShortcutStore.swift
//
//  快捷项目 = 「一键刷新信号」这类东西的骨架。
//
//  两种：
//    ① 打开某个 App（kind = app，id = bundleID）
//    ② 内置动作（kind = action，id = ShortcutAction）—— 刷新信号、移动球、打开列表…
//
//  存在 App 和悬浮球进程共享的那个 plist 里，两边读同一份（见 hud-prefix.pch）。
//  手势绑定里存的是 key（"app:xxx" / "action:xxx"），不存下标 ——
//  这样快捷列表增删排序都不会把绑定搞乱。
//

import Foundation

// MARK: - 内置动作

enum ShortcutAction: String, CaseIterable, Identifiable {
    case refreshSignal      // 刷新蜂窝信号
    case openMainApp        // 打开悬浮球主界面
    case openAppList        // 打开快捷应用列表
    case moveBall           // 移动悬浮图标
    case toggleLabel        // 显示 / 隐藏球上的数字
    case none               // 什么都不做

    var id: String { rawValue }

    var title: String {
        switch self {
        case .refreshSignal: return "刷新信号"
        case .openMainApp:   return "打开悬浮球"
        case .openAppList:   return "打开快捷列表"
        case .moveBall:      return "移动悬浮图标"
        case .toggleLabel:   return "显示/隐藏数字"
        case .none:          return "什么都不做"
        }
    }

    /// 列表里那行小字
    var detail: String {
        switch self {
        case .refreshSignal: return "卡贴机没信号 / 假信号时点一下，让基带重新搜网"
        case .openMainApp:   return "回到悬浮球 App 的「启动」页"
        case .openAppList:   return "回到悬浮球 App 的「快捷应用」页"
        case .moveBall:      return "球变成可拖动状态，拖着放到顺手的位置"
        case .toggleLabel:   return "球上那个数字显示 / 不显示"
        case .none:          return "不做事"
        }
    }

    var symbol: String {
        switch self {
        case .refreshSignal: return "antenna.radiowaves.left.and.right"
        case .openMainApp:   return "app.badge"
        case .openAppList:   return "square.grid.2x2"
        case .moveBall:      return "hand.draw"
        case .toggleLabel:   return "textformat.123"
        case .none:          return "slash.circle"
        }
    }
}

// MARK: - 快捷项目

struct ShortcutItem: Identifiable, Equatable {
    enum Kind: String {
        case app    = "app"
        case action = "action"
    }

    var kind: Kind
    var id: String          // app -> bundleID；action -> ShortcutAction.rawValue
    var title: String

    /// 手势绑定 / 去重用的唯一 key
    var key: String { "\(kind.rawValue):\(id)" }

    /// 内置动作（用来判断它能不能在 App 里直接执行）
    var action: ShortcutAction? {
        kind == .action ? ShortcutAction(rawValue: id) : nil
    }

    var symbol: String {
        switch kind {
        case .app: return "app"
        case .action: return action?.symbol ?? "questionmark"
        }
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

    static func load() -> [ShortcutItem] {
        let dict = UserDefaults().loadUserDefaults(forPath: BallSettings.path)
        guard let raw = dict[shortcutsKey] as? [[String: Any]] else {
            return defaults
        }
        let items: [ShortcutItem] = raw.compactMap { row in
            guard let kindRaw = row["kind"] as? String,
                  let kind = ShortcutItem.Kind(rawValue: kindRaw),
                  let id = row["id"] as? String,
                  let title = row["title"] as? String
            else { return nil }
            return ShortcutItem(kind: kind, id: id, title: title)
        }
        return items.isEmpty ? defaults : items
    }

    static func save(_ items: [ShortcutItem]) {
        let raw: [[String: Any]] = items.map {
            ["kind": $0.kind.rawValue, "id": $0.id, "title": $0.title]
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
        if let item = items.first(where: { $0.key == key }) { return item.title }
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
