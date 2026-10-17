import SwiftUI

/// 第二栏：快捷菜单
///
/// 三种条目：
///   · 打开某个 App
///   · 内置动作库里的动作（刷新信号 / 全局返回 / 截屏 / 移动悬浮图标 / 打开菜单…）
///   · URL 协议 / 系统快捷指令（微信扫一扫、shortcuts://run-shortcut?name=…）
///
/// 这一栏既是「手动点一下」的清单，也是手势绑定的候选池（见「启动」页的手势一节）。
///
/// ⚠️ 排序**不用系统的「编辑」模式**（2026-10-17 用户要求）：
///    编辑模式的删除圈和「左滑删除」重复，而且编辑模式下点一行不会执行动作。
///    改法：常驻拖动 —— 每行右边是三条横线的手柄，手指按住一行拖到哪就插到哪
///    （`.onDrag` + `ShortcutDropDelegate`），点一下照样执行、左滑照样删。
struct AppsTab: View {

    @State private var items: [ShortcutItem] = []
    @State private var showAdd = false
    @State private var message = ""
    @State private var showMessage = false
    /// 正在被拖着的那一行（排序用）
    @State private var dragging: ShortcutItem?

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("菜单项"),
                        footer: Text("点一行就执行。右边那三条横线是拖动手柄：按住一行拖到别处就换顺序。左滑一行可以删除。这里的每一项也能绑到手势上。")) {
                    if items.isEmpty {
                        Text("还是空的，点下面「添加」").foregroundColor(.secondary)
                    }
                    ForEach(items) { item in
                        row(item)
                            .contentShape(Rectangle())
                            .onTapGesture { run(item) }
                            // 常驻拖动：按住一行拖走。松手（performDrop）时才写盘，
                            // 免得拖的过程中每移一格都写一次 plist。
                            .onDrag {
                                dragging = item
                                return NSItemProvider(object: item.key as NSString)
                            }
                            // ⚠️ 这里用 [String] 那个老重载：iOS 13.4 就有，
                            //    比 [UTType] 那版稳（本机没有 Xcode，不能先编译验证）。
                            .onDrop(of: ["public.text"], delegate: ShortcutDropDelegate(
                                item: item,
                                items: $items,
                                dragging: $dragging,
                                onCommit: { ShortcutStore.save($0) }
                            ))
                    }
                    .onDelete { offsets in
                        items.remove(atOffsets: offsets)
                        ShortcutStore.save(items)
                    }
                }

                Section {
                    Button {
                        showAdd = true
                    } label: {
                        Label("添加", systemImage: "plus.circle")
                    }
                    Button("恢复默认三条") {
                        items = ShortcutStore.defaults
                        ShortcutStore.save(items)
                    }
                }
            }
            .navigationTitle("快捷菜单")
        }
        .onAppear { items = ShortcutStore.load() }
        .sheet(isPresented: $showAdd) {
            AddShortcutView(existing: items) { item in
                items.append(item)
                ShortcutStore.save(items)
            }
        }
        .alert(isPresented: $showMessage) {
            Alert(title: Text("提示"), message: Text(message), dismissButton: .default(Text("好")))
        }
    }

    // MARK: - 行

    private func row(_ item: ShortcutItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .frame(width: 26)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                Text(item.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // 拖动手柄：老版本这里是「>」（点进二级页的箭头），
            // 现在点一行就是执行，没有二级页可进 —— 所以换成能拖的表示。
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 执行

    private func run(_ item: ShortcutItem) {
        switch item.kind {
        case .app:
            Haptics.fire(.tap)
            if !FBOpenApplication(item.id) {
                say("打不开 \(item.displayTitle)（可能是没装，或者系统不让从这儿跳）")
            }

        case .url:
            // URL 协议 / 系统快捷指令都走同一条：把 URL 交给系统。
            // ⚠️ 只能知道「系统收下了」，不知道对面有没有真执行 ——
            //    例如系统快捷指令的名字写错了，「快捷指令」App 自己会提示找不到。
            Haptics.fire(.tap)
            if !FBOpenURL(item.id) {
                say("打不开这个链接：\n\(item.id)\n\n可能是没装对应的 App，或者这条 scheme 不对。")
            }

        case .action:
            guard let action = item.action else { return }
            switch action {
            case .none:
                Haptics.fire(.tap)

            case .refreshSignal:
                // ⚠️ 这一步没有回执：请求交给 CommCenter 就结束了，成没成只能看信号格
                //    所以用「通知」那种震感表示「交代出去了」，不表示成功
                Haptics.fire(.notice)
                let sent = FBRefreshCellularSignal()
                say(sent
                    ? "已经让基带重新搜网。\n\n⚠️ 这一步没有回执，别等我告诉你成功——直接看状态栏信号格回没回来。"
                    : "这次发不出去：这台机器上缺权限，或者系统里没有这个接口。")

            case .openMainApp:
                Haptics.fire(.tap)
                TabRouter.shared.tab = 0

            case .openAppList:
                Haptics.fire(.tap)
                TabRouter.shared.tab = 1

            case .goBack:
                // ⚠️ 不在 App 里注入：这时候 App 自己就是前台，划出来也没地方可返回。
                //    这个动作只在屏幕上的球上触发才有意义（那边走 HUD 的 performAction）。
                Haptics.fire(.tap)
                say("「全局返回」得在屏幕上的球上触发才有意义——在 App 自己里划「返回」没意义。\n\n"
                    + "绑到手势上：回「启动」页 →「手势」那一栏，点单击/双击/长按的右边，选「全局返回」。")

            case .screenshot:
                // 【截屏】在 App 里也能截（同一个二进制、同一份 entitlements）。
                //   ① 优先走系统截图服务（ScreenshotServices）—— 不注入任何输入，最安全；
                //   ② 那条路走不通才注入「音量加 + 电源」组合键。
                Haptics.fire(.action)
                let route = FBTakeScreenshot()
                if route == 1 {
                    say("截屏：走的是系统截图服务。画面会闪一下，图在「相册 → 截屏」。")
                } else if route == 2 {
                    say("截屏：走的是按键注入（音量加 + 电源）。画面闪一下、图进「相册 → 截屏」。\n\n"
                        + "⚠️ 如果屏幕只是锁上了，说明这一下没被认成组合键 —— 解锁继续用就行，不丢东西。")
                } else {
                    say("这次没截成：① 系统截图服务那条路取不到，② 按键注入也没条件。\n\n"
                        + "详情在 /tmp/FloatingBall.log（「截屏：…」那几行）。")
                }

            case .moveBall:
                Haptics.fire(.tap)
                say("「移动悬浮图标」得在屏幕上的球上触发才有意义——在 App 里挪不了球。")

            case .toggleLabel:
                Haptics.fire(.action)
                let now = BallSettings.bool("ShowLabel", default: true)
                BallSettings.set(!now, "ShowLabel")
                BallSettings.notifyReload()
                say(!now ? "球上的数字打开了。" : "球上的数字关掉了。")
            }
        }
    }

    private func say(_ text: String) {
        message = text
        showMessage = true
    }
}

// MARK: - 拖动排序

/// 常驻拖动排序的落点逻辑：
/// 拖着某一行进到另一行身上时，就把它插到那一行的位置（上下方向都对：
/// 往下拖时插到对方后面、往上拖时插到对方前面）。
/// ⚠️ 松手才写盘（`onCommit`）—— 拖的过程中每移一格都写一次 plist 太亏。
struct ShortcutDropDelegate: DropDelegate {

    let item: ShortcutItem
    @Binding var items: [ShortcutItem]
    @Binding var dragging: ShortcutItem?
    let onCommit: ([ShortcutItem]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging,
              dragging != item,
              let from = items.firstIndex(of: dragging),
              let to = items.firstIndex(of: item)
        else { return }

        if items[to] != dragging {
            withAnimation(.easeInOut(duration: 0.18)) {
                items.move(fromOffsets: IndexSet(integer: from),
                           toOffset: to > from ? to + 1 : to)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        onCommit(items)
        return true
    }
}

// MARK: - 添加

struct AddShortcutView: View {

    let existing: [ShortcutItem]
    let onPick: (ShortcutItem) -> Void

    @Environment(\.presentationMode) private var presentationMode
    @State private var query = ""
    @State private var apps: [ShortcutItem] = []
    /// 「系统快捷指令」那一行填的名字
    @State private var shortcutName = ""
    /// 「URL 协议」里自己填的 URL
    @State private var customURL = ""
    @State private var hint = ""

    private var usedKeys: Set<String> { Set(existing.map { $0.key }) }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("内置动作库")) {
                    ForEach(ShortcutAction.allCases.filter { $0 != .none }) { action in
                        optionRow(ShortcutItem.make(action: action),
                                  detail: action.detail,
                                  symbol: action.symbol)
                    }
                }

                // ---- 新增的一栏（2026-10-17 用户要求）----
                // 位置就在「内置动作库」和「已安装的 App」之间；
                // 两块内容**都在这一页里**：不做二级页面、不做折叠页。
                Section(header: Text("添加"),
                        footer: Text("系统快捷指令 = 「快捷指令」App 里那条指令，名字要写一样（中文、空格都算）。\n"
                                     + "URL 协议 = 别的 App 留的口子：下面三条是内置的，也可以自己填一条。\n"
                                     + "⚠️ 只能知道「系统收下了这个请求」；名字写错时是「快捷指令」App 自己提示找不到。")) {
                    systemShortcutRows
                    urlRows
                }

                Section(header: Text("已安装的 App（\(apps.count)）")) {
                    ForEach(filteredApps) { item in
                        optionRow(item, detail: item.id, symbol: "app")
                    }
                }

                if !hint.isEmpty {
                    Section(footer: Text(hint)) { EmptyView() }
                }
            }
            .searchable(text: $query, prompt: "搜 App 名字")
            .navigationTitle("添加")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .onAppear {
            guard apps.isEmpty else { return }
            // 注意：这是**同步**去问 LSApplicationWorkspace 要名单，
            // 名字多的机器上会卡一下（几百毫秒），可以接受。
            apps = FBInstalledApps().compactMap { dict in
                guard let id = dict["id"], let name = dict["name"] else { return nil }
                return ShortcutItem(kind: .app, id: id, title: name)
            }
        }
    }

    // MARK: 系统快捷指令 / URL 协议（同一页）

    @ViewBuilder
    private var systemShortcutRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("系统快捷指令")
            } icon: {
                Image(systemName: BuiltinURLs.shortcutIcon).foregroundColor(.accentColor)
            }
            Text("填「快捷指令」App 里那条指令的名字")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                TextField("例如：一键回家", text: $shortcutName)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Button("添加") { addSystemShortcut() }
                    .disabled(shortcutName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var urlRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("URL 协议")
            } icon: {
                Image(systemName: "link").foregroundColor(.accentColor)
            }
            Text("点一下就加进菜单；下面三条是内置的常用入口")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                TextField("也可以自己填，如 weixin://scanqrcode", text: $customURL)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                Button("添加") { addCustomURL() }
                    .disabled(customURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.vertical, 2)

        ForEach(BuiltinURLs.presets) { preset in
            optionRow(preset.item, detail: preset.url, symbol: preset.icon)
        }
    }

    // MARK: 加项

    private func addSystemShortcut() {
        let name = shortcutName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let item = ShortcutItem(kind: .url,
                               id: BuiltinURLs.shortcutURL(name: name),
                               title: name,
                               icon: BuiltinURLs.shortcutIcon)
        pick(item)
        shortcutName = ""
    }

    private func addCustomURL() {
        let raw = customURL.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        // 没写 scheme 就没法当 URL 打开，先拦一下（不然加进去也是坏的）
        guard raw.contains("://") else {
            hint = "「\(raw)」不像一条 URL —— 要带 scheme，例如 weixin://scanqrcode。"
            return
        }
        let item = ShortcutItem(kind: .url, id: raw, title: raw, icon: "link")
        pick(item)
        customURL = ""
    }

    private func pick(_ item: ShortcutItem) {
        if usedKeys.contains(item.key) {
            hint = "「\(item.displayTitle)」已经在菜单里了。"
            return
        }
        hint = ""
        onPick(item)
        presentationMode.wrappedValue.dismiss()
    }

    // MARK: App 名单

    private var filteredApps: [ShortcutItem] {
        apps.filter { item in
            if usedKeys.contains(item.key) { return false }
            if query.isEmpty { return true }
            return item.title.localizedCaseInsensitiveContains(query)
                || item.id.localizedCaseInsensitiveContains(query)
        }
    }

    private func optionRow(_ item: ShortcutItem, detail: String, symbol: String) -> some View {
        let used = usedKeys.contains(item.key)
        return Button {
            onPick(item)
            presentationMode.wrappedValue.dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 26)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle).foregroundColor(.primary)
                    Text(used ? "已经在列表里了" : detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if used {
                    Image(systemName: "checkmark").foregroundColor(.secondary)
                }
            }
        }
        .disabled(used)
    }
}
