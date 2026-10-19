import SwiftUI

/// 第二栏：快捷菜单
///
/// 三种条目：
///   · 打开某个 App
///   · 内置动作库里的动作（刷新信号 / 全局返回 / 截屏 / 移动悬浮图标 / 打开菜单…）
///   · URL 协议 / 系统快捷指令（微信扫一扫、shortcuts://run-shortcut?name=…）
///
/// 这一栏既是「手动点一下」的清单，也是手势绑定的候选池（手势那一节就在下面，0.1.32 起）。
///
/// ⚠️ 排序**不用系统的「编辑」模式**（2026-10-17 用户要求），也**不走 `.onDrag`/`.onDrop`**
///    （那条在 2026-10-18 被真机证伪：手柄显示出来了，但拖动调不了顺序）。
///    现在的改法：`ForEach` 挂 `.onMove(perform:)` —— SwiftUI 的 List 自带
///    **长按一行就能拖着换位置**的能力（Apple 文档明说「by using a long press on a row」，
///    不需要进编辑模式），每行右边照旧画着三条横线当「能拖」的示意。
///    点一下照样执行、左滑照样删，排序时松手就写盘。
struct AppsTab: View {

    @State private var items: [ShortcutItem] = []
    @State private var gestures: [String: String] = [:]
    /// 0.1.36：打开手势选择菜单时能选的东西（用户自己增删，见下面「手势动作」那一节）
    @State private var gestureItems: [ShortcutItem] = []
    @State private var showAdd = false
    @State private var showAddGesture = false
    @State private var message = ""
    @State private var showMessage = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("菜单项"),
                        footer: Text("点一下就执行。想换顺序：**长按**一行（那三条横线的位置最好使）往上拖，松手就定位置。左滑一行可以删除。\n这一栏就是球上双击弹出来的快捷菜单。")) {
                    if items.isEmpty {
                        Text("还是空的，点下面「添加」").foregroundColor(.secondary)
                    }
                    ForEach(items) { item in
                        row(item)
                            .contentShape(Rectangle())
                            .onTapGesture { run(item) }
                    }
                    // ⚠️ 排序就这一句：List 对挂了 onMove 的 ForEach 自带「长按+拖动」。
                    //    每换一次位置就写一次盘（plist 很小，写盘反而稳 —— 中途退出去也不丢）。
                    .onMove { from, to in
                        items.move(fromOffsets: from, toOffset: to)
                        ShortcutStore.save(items)
                    }
                    .onDelete { offsets in
                        items.remove(atOffsets: offsets)
                        ShortcutStore.save(items)
                    }

                    // 0.1.36（用户要求）：「添加」从页面最底下挪到菜单项列表的末尾 ——
                    // 加完一条就往回看，不用再滑到最下面。
                    Button {
                        showAdd = true
                    } label: {
                        Label("添加", systemImage: "plus.circle")
                    }
                }

                // ⚠️ 0.1.32（用户要求）：手势绑定从「启动」页搬到这一页。
                //    理由：这一页既是「点一下」的清单，也是手势的候选池；
                //    手势和菜单项本来就是一件事的两个入口，放在一起改更顺。
                //    绑定关系 / 默认值 / 存盘键都没变（还是 GestureTap / GestureDoubleTap /
                //    GestureLongPress），老的绑定照常生效。
                Section(header: Text("手势"),
                        footer: Text("每条手势各绑一个动作，右边就是当前绑的是哪个。默认：单击 = 打开「设置」，双击 / 长按 = 什么都不做。拖动固定是移动球。球上的数字是「点到了」的回执。\n能选的东西就是下面「手势动作」那一栏列出来的 —— 觉得菜单乱，就去那里删几条。")) {
                    ForEach(ShortcutStore.gestureKeys) { entry in
                        gestureRow(title: entry.title, key: entry.id)
                    }
                    HStack {
                        Text("拖动")
                        Spacer()
                        Text("移动球，松手吸边").foregroundColor(.secondary)
                    }
                }

                // ⚠️ 0.1.36（用户 2026-10-20 要求）：手势下面再加一节「手势动作」。
                //    这一节就是「打开手势选择菜单时能选的动作」的清单 ——
                //    原来那个菜单把全部内置动作 + 所有 App/URL 平铺，几十项，很乱。
                //    现在只列这里有的；想加就点「添加手势项目」，想少就左滑删。
                Section(header: Text("手势动作"),
                        footer: Text("这里列出来的，就是点「单击 / 双击 / 长按」右边时那个菜单里能选的东西。\n"
                                     + "左滑删除；想加新的点「添加手势项目」（App、URL 协议、系统快捷指令都能加）。\n"
                                     + "⚠️ 和上面「菜单项」是两份独立的清单：删这里的不会动球的快捷菜单，反之亦然。")) {
                    if gestureItems.isEmpty {
                        Text("空的 —— 点下面「添加手势项目」").foregroundColor(.secondary)
                    }
                    ForEach(gestureItems) { item in
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
                        }
                    }
                    .onDelete { offsets in
                        gestureItems.remove(atOffsets: offsets)
                        ShortcutStore.saveGestureItems(gestureItems)
                    }

                    Button {
                        showAddGesture = true
                    } label: {
                        Label("添加手势项目", systemImage: "hand.tap")
                    }
                }

                Section {
                    Button("恢复默认三条") {
                        items = ShortcutStore.defaults
                        ShortcutStore.save(items)
                    }
                }
            }
            .navigationTitle("快捷菜单")
        }
        .onAppear {
            items = ShortcutStore.load()
            gestureItems = ShortcutStore.loadGestureItems()
            // 0.1.32：手势绑定也搬到这一页了，一起读
            for entry in ShortcutStore.gestureKeys {
                gestures[entry.id] = ShortcutStore.gestureTarget(entry.id)
            }
        }
        .sheet(isPresented: $showAdd) {
            AddShortcutView(existing: items) { item in
                items.append(item)
                ShortcutStore.save(items)
            }
        }
        // 0.1.36：加的是「手势动作」，不是菜单项 —— 两份清单，各存各的。
        .sheet(isPresented: $showAddGesture) {
            AddShortcutView(existing: gestureItems) { item in
                gestureItems.append(item)
                ShortcutStore.saveGestureItems(gestureItems)
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
            //三条横线手柄：老版本这里是「>」（点进二级页的箭头），
            // 现在点一行就是执行，没有二级页可进 —— 换成「能拖着换顺序」的示意。
            // 真正的排序靠 List 自带的「长按+拖」（onMove），从这附近按下去最顺手。
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 手势绑定（0.1.32 从「启动」页搬来）

    /// 一条手势的绑定行：**右边直接显示现在绑的是哪个动作**（2026-10-17 要求），
    /// 点开是个菜单 —— 0.1.36 起这里只列「手势动作」那一节里的东西（用户自己维护）。
    private func gestureRow(title: String, key: String) -> some View {
        let current = gestures[key] ?? ShortcutStore.gestureTarget(key)

        // 0.1.36：候选池 = 「手势动作」那一栏。
        // 当前绑的如果不在池子里（老版本绑过、或者刚从池子里删掉），临时补一条进来，
        // 不然菜单里看不到「现在绑的是它」，也没法把它改回未设置。
        var pool = gestureItems
        if !current.isEmpty, !pool.contains(where: { $0.key == current }) {
            if let act = action(fromKey: current) {
                pool.append(.make(action: act))
            } else if let item = items.first(where: { $0.key == current }) {
                pool.append(item)
            }
        }

        // 菜单里勾出当前这条：Menu 里的按钮不吃 Picker 的选中态，自己画个 ✓
        func marked(_ target: String) -> String { target == current ? "✓ " : "" }
        let noneMark = marked("")

        return Menu {
            Button("\(noneMark)未设置") { setGesture(key, "") }

            if !pool.isEmpty {
                Divider()
                ForEach(pool) { item in
                    Button("\(marked(item.key))\(item.displayTitle)") { setGesture(key, item.key) }
                }
            }
        } label: {
            HStack {
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                Text(ShortcutStore.title(forKey: current, in: items))
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
    }

    /// "action:xxx" → ShortcutAction（别的写法返回 nil）
    private func action(fromKey key: String) -> ShortcutAction? {
        guard key.hasPrefix("action:") else { return nil }
        return ShortcutAction(rawValue: String(key.dropFirst("action:".count)))
    }

    /// 改一条手势的绑定（存起来 + 通知球进程重读）
    private func setGesture(_ key: String, _ target: String) {
        gestures[key] = target
        ShortcutStore.setGestureTarget(key, target)
        Haptics.fire(.tap)
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

            case .quitBall:
                // 0.1.34（用户要求）：「关闭悬浮球」= 把球收掉。
                // 走的是和「启动」页那个开关完全相同的入口（spawn -exit 收尾）。
                Haptics.fire(.action)
                if IsHUDEnabledBridger() {
                    SetHUDEnabledBridger(false)
                    say("球收掉了。\n\n想再开：回「启动」页把「启动悬浮球」打开。")
                } else {
                    say("球本来就没开（「启动」页那个开关现在是关的）。")
                }

            case .openAppList:
                Haptics.fire(.tap)
                TabRouter.shared.tab = 1

            case .goBack:
                // ⚠️ 不在 App 里注入：这时候 App 自己就是前台，划出来也没地方可返回。
                //    这个动作只在屏幕上的球上触发才有意义（那边走 HUD 的 performAction）。
                Haptics.fire(.tap)
                say("「全局返回」得在屏幕上的球上触发才有意义——在 App 自己里划「返回」没意义。\n\n"
                    + "绑到手势上：回「快捷菜单」页 →「手势」那一栏，点单击/双击/长按的右边，选「全局返回」。")

            case .screenshot:
                // 【截屏】在 App 里也能截（同一个二进制、同一份 entitlements）。
                //   ① 优先让 SpringBoard 自己截（AXSpringBoardServer 的 XPC，辅助触控同一条）；
                //   ② 那条路取不到才注入「音量加 + 电源」组合键。
                Haptics.fire(.action)
                let route = FBTakeScreenshot()
                if route == 1 {
                    say("截屏：已经交给系统了（走的是辅助触控「截屏」那条通道）。\n"
                        + "画面会闪一下，图在「相册 → 截屏」。\n\n"
                        + "如果没截到，看 /tmp/FloatingBall.log 里「截屏：…」那几行 —— 会自动退到按键注入。")
                } else {
                    say("这次没发起：上一次截屏请求还没回来。等一两秒再点一次就行。\n\n"
                        + "如果一直这样，把 /tmp/FloatingBall.log 里「截屏：…」那几行发我。")
                }

            case .mailInbox:
                // ⚠️ 和「全局返回」一样：这一条靠**往系统注入触摸**，而只有球那个 HUD 进程
                //    才学得到这台机器的触摸身份（sender ID）；App 进程学不到，注入会被系统丢掉。
                //    所以在这儿点它只会把 Mail 拉起来、后面两步不会发生 —— 不如直接指路。
                Haptics.fire(.tap)
                say("「打开邮箱收件箱」得在屏幕上的球上点才有意义 —— "
                    + "它要做的是往系统里注入「点一下 + 划一次返回」，"
                    + "而只有球的后台进程有这个身份。\n\n"
                    + "想随手用：回「快捷菜单」页，把它加到「手势动作」里绑给长按，或者加到菜单项里。")

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
// MARK: - 添加

/// ⚠️ 0.1.13：`ShortcutDropDelegate`（onDrag/onDrop 那套）删了 ——
///    0.1.10 写它时没条件真机验证，结果手柄能显示、顺序拖不动；排序改交给
///    `ForEach.onMove`（长按+拖），结构简单一半。此段留个说明，别再写回来。

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

    /// 搜索框里有字 → 只显示「已安装的 App」这一块（内置动作库/添加两块先收起来）。
    /// 用户搜的是 App 名字，把动作库顶在前面纯属挡路（2026-10-18 反馈）。
    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationView {
            // ⚠️ 0.1.13（用户 2026-10-18 要求）：搜索框不再用 `.searchable`
            //    （那个是塞在导航栏下面，位置不动，也不属于 App 列表）。
            //    改法：**常驻顶部的固定一行**，就在 App 列表头上；
            //    往下滑列表时它不动 —— 滑到「已安装的 App」再往上翻也能照常搜。
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜 App 名字", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                Divider()
                List {
                // ⚠️ 0.1.15（用户 2026-10-18 反馈）：一开始搜索，结果最前面却是「内置动作库」，
                //    而用户搜的是 **App 名字**。所以只要搜索框里有字，就把上面两块先收起来，
                //    让「已安装的 App」直接顶到第一条 —— 搜什么就只看什么。
                if !isSearching {
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
            }
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
