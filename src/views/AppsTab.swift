import SwiftUI

/// 第二栏：快捷列表
///
/// 两种条目：
///   · 打开某个 App
///   · 内置动作（刷新信号 / 移动悬浮图标 / 打开列表…）
///
/// 这一栏既是「手动点一下」的清单，也是手势绑定的候选池（见「启动」页的手势一节）。
struct AppsTab: View {

    @State private var items: [ShortcutItem] = []
    @State private var showAdd = false
    @State private var message = ""
    @State private var showMessage = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("快捷列表"),
                        footer: Text("点一行就执行。右上角「编辑」可以拖动排序、左滑删除。这里的每一项也能绑到手势上。")) {
                    if items.isEmpty {
                        Text("还是空的，点下面「添加」").foregroundColor(.secondary)
                    }
                    ForEach(items) { item in
                        Button {
                            run(item)
                        } label: {
                            row(item)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        items.remove(atOffsets: offsets)
                        ShortcutStore.save(items)
                    }
                    .onMove { from, to in
                        items.move(fromOffsets: from, toOffset: to)
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
            .navigationTitle("快捷应用")
            .toolbar { EditButton() }
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
                Text(item.title)
                Text(item.action?.detail ?? item.id)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: - 执行

    private func run(_ item: ShortcutItem) {
        switch item.kind {
        case .app:
            Haptics.fire(.tap)
            if !FBOpenApplication(item.id) {
                say("打不开 \(item.title)（可能是没装，或者系统不让从这儿跳）")
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

// MARK: - 添加

struct AddShortcutView: View {

    let existing: [ShortcutItem]
    let onPick: (ShortcutItem) -> Void

    @Environment(\.presentationMode) private var presentationMode
    @State private var query = ""
    @State private var apps: [ShortcutItem] = []

    private var usedKeys: Set<String> { Set(existing.map { $0.key }) }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("内置动作")) {
                    ForEach(ShortcutAction.allCases.filter { $0 != .none }) { action in
                        optionRow(ShortcutItem.make(action: action),
                                  detail: action.detail,
                                  symbol: action.symbol)
                    }
                }

                Section(header: Text("已安装的 App（\(apps.count)）")) {
                    ForEach(filteredApps) { item in
                        optionRow(item, detail: item.id, symbol: "app")
                    }
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
                    Text(item.title).foregroundColor(.primary)
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
