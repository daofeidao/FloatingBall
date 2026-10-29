import SwiftUI
import Combine

struct AboutTab: View {

    /// 只是用来戳一下刷新（值变了 body 就重算）
    @State private var probeTick = 0
    /// 0.1.42：点「版本」那一行才弹出这张历史表（原来它挂在首页的 `*` 里）
    @State private var showingVersion = false

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return v ?? "?"
    }

    /// 版本记录（0.1.42 起从首页搬到这里，点「版本」那一行看）。
    private static let versionHistory = """
    0.1.43：**把「返回」的注入速度退回 0.1.40 那一组** —— 0.1.41 为了让返回更快，把采样点从 8 个加到 16 个、每步 42 毫秒压到 10 毫秒（约 590 → 1040 pt/s）。之后真机上出现「球点不动、拖不动、点球反而点到下面的 App」，而且把球关掉再打开也不恢复。这一版除速度之外**什么都不动**：一次只改一个变量，才判断得出到底是不是它。要是退回之后一切正常，说明问题就在那组更快的参数上，提速得换个做法再谈。
    0.1.42：**界面清理**（用户要求）—— 首页的「轻点次数」删掉（球上那个数字也一起去掉，「显示/隐藏数字」这个动作同样删了：老列表里那条会自动消失，绑在它上面的手势改成「什么都不做」）；按球不再缩一下（震动保留）；首页那些 `*` 长说明、排障、版本记录整块移除，只剩开关和外观设置。版本记录挪到这里 —— 点「版本」这一行看历史，点「标识」这一行打开项目的 GitHub 页面。
    0.1.41：**返回划得更快、更顺** —— 采样点从 8 个加到 16 个，每步间隔从 42 毫秒压到 10 毫秒，整段划动的实际速度大约从 590 pt/s 提到 1000 pt/s 上下，返回动画跟手多了；「按下后先按住 70 毫秒再起划」保留（那是识别器判断「这是有意的边缘手势」的关键）。速度仍留在安全区以内 —— 再快就会退回「快速轻扫」那一档，识别器不认，划出去会变成下面 App 的横向翻页。
    0.1.40：**修「点球又把下面的 App 点到」** —— 0.1.39 补上「边缘标记」让返回真的通了，但那串事件里「抬起」那一条还在说「这只手还按在屏幕上」（父事件的 Range/Touch 写的是 1/1），系统把它当成一次真实的边缘手势，状态就一直停在「手势进行中」，之后球上那一下不再被我们吃掉、原样漏给下面的 App。现在抬起会如实报告「手已经离开屏幕」；返回手势后面那条 500 毫秒的兜底抬起也不再冒充「从边缘抬起」。返回本身照旧可用。
    0.1.39：**修「全局返回」** —— 真正的原因不是速度，是缺了一个「边缘标记」：真机手指从屏幕边缘起手时，系统会给这一整段触摸打上「来自边缘」的标记，而「返回」这个手势只认带标记的触摸。我们照老配方注入时没带这个标记，划出去就被当成普通横向滑动（你早先看到的「像在左右滑动切换」就是它）。现在按下、移动、抬起三条事件都带上了这个官方标记位，划动才会被认成「从边缘返回」。日志里会多一行「边缘标记=FromEdgeTip(0x800) 已带上」。
    0.1.38：**震动改成「只在按下去那一下」** —— 单击震 1 下、双击震 2 下、长按震 1 下；抬手不再震（用户 2026-10-20：「点下去它震一下手，抬起来它震一下」）。**修长按不执行**：按住不动时数字器不发事件，我们那个 0.18 秒的兜底会提前把触点交还，长按（要 0.5 秒）永远等不到 —— 现在按住不动时放宽到 0.6 秒，并把「同一根手指还在按着」的伪起手排除掉（不再每隔一秒震一下）；长按的容错距离从 10pt 放到 26pt，手抖也不会失败。**不透明度最低改 20%**（原来 30%）。**新增「闲置时淡化缩小」**：一段时间没碰球就自己淡到最淡、缩到最小，手指一碰立刻恢复（秒数可选 3/5/10/30）。**自定义图标能「选一块」了**：选完相册里那张图会出来一页裁剪，拖动 + 双指缩放，把要的部分对进圆圈（以前只能自动居中填满）；换过的图还留 3 张，点一下就换回去。**每一页下面的长说明收成小节标题右边的 `*`**，点开才看，页面整齐。
    0.1.37：「打开邮箱收件箱」的等待改成**轮询** —— 开机就动手，不再固定等 1.6 秒（热启动时原来那 1.6 秒纯属白等）。判断「Mail 到前台了」用系统的前台查询，一到就点一下空白再划返回；要是等了 2.5 秒 Mail 都没起来，这一下就干脆不注入（免得瞎点到别的界面）。
    0.1.36：**快捷菜单页整理 + 球上菜单不再只出 8 项 + 新增「打开邮箱收件箱」**。「添加」挪到菜单项列表末尾；手势下面新增「手势动作」，那里列的就是点单击/双击/长按时能选的东西，觉得菜单乱就左滑删几条；「移动悬浮图标」删掉了（球直接拖就能挪）；球上的快捷菜单原来最多只出 8 项，现在有多少出多少，装不下可以上下拖着看。新增「打开邮箱收件箱」：把 Mail 拉到前台，点一下上方空白，再划一次返回 —— 专门治「Mail 停在带附件的邮件详情页，光划返回划不动」。
    0.1.35：**截屏不带球了**。系统截图抓的是整块屏幕，球挂在窗口上就一定会被拍进去，所以改成「先把球藏起来 → 0.3 秒后让系统截 → 1.2 秒后把球放回」；藏起来的这一小会儿，球那一片的触摸也会放过去，不会吃了你的手指。
    0.1.34：**「打开悬浮球」改成「关闭悬浮球」**。球就在屏幕上，这个菜单项拿来把球收掉更顺手：点了之后球淡出消失，等于回「启动」页把开关关一下。老列表里那条「打开悬浮球」会自动换成它（只换一次）；「打开悬浮球」本身还在动作库里，想加回来随时能加。
    0.1.33：**修「点截屏，球直接没了」**。球消失＝球的后台进程崩了：0.1.32 用的 ScreenshotServices 那个类其实是 SpringBoard 内部的东西，在别的进程里初始化会崩。现在改成让 SpringBoard 自己截（辅助触控「截屏」走的同一条系统通道），我们只发一条消息、不碰截图实现；万一这条路取不到，才退回「音量加 + 电源」按键注入。
    0.1.32：① 把手势区从「启动」页搬到「快捷菜单」页（菜单项列表下面）—— 这一页本来就是「菜单项 + 手势候选池」，放一起改更顺。绑定关系、默认值、存盘键都不变，老绑定照用。② 震动改短：**只震一下、最长 40ms**（"刷新信号"也不再敲两下）；强度改用**时长**区分（20% ≈ 14ms / 100% = 40ms），因为系统声音振动的 `Intensity` 参数在 iOS 15 上不生效。③ 点球开菜单更快：原来单击必须等双击判定失败（约 0.3 秒），现在**双击没绑动作时不再等**，点完立刻弹出。
    0.1.31：**修「震动强度设定没作用」—— 其实从来就没震过**：球是后台 root 进程，UIImpactFeedbackGenerator 的反馈只在前台有效、后台会被系统吞掉（所以强度滑块怎么拖都没用）。改成系统声音振动（AudioServicesPlaySystemSoundWithVibration），后台也能震、强度真的可调；每次震动前还从磁盘重读一次开关和强度。
    0.1.30：**0.1.29 的补强（直接发这版）** —— ① 菜单上的触摸不再缩球：原来菜单开着时整屏接管，每根手指落下都走 FBBallHapticTouchDown()，表现为「点哪里球都缩一下」的全局反馈；现在只有按在球上才缩。② 菜单行按下高亮；容器加触摸日志（按下/抬起/行号），点不动时能直接看出触摸有没有进来。
    0.1.29：**修「快捷菜单点不动」** —— 菜单项原来是 UIControl，靠 touchUpInside 触发；合成触摸的「抬起」坐标在本机经常丢（[rep location] 恒 (0,0)），UIControl 严格要求「抬起时还在这一行」，坐标一丢就判成在外面松手。改成：菜单容器自己收触摸（touchesBegan/Ended），按坐标算行号；HUD 侧把菜单上的触摸直接喂给容器，不依赖 hitTest；所有 Ended 统一喂在最后一次好坐标上。菜单行按下有高亮。
    0.1.25：修「拖球移不动 / 原地缩放」：`sLastFedPoint` 原来存的是**未经修正的坐标**（winPt），而「坐标不可信就沿用上一帧」靠它续命 —— 一旦某一帧坐标读不到（拖动中手指移出球、或这台设备 `[rep location]` 恒为 (0,0)），坏点就被永久记住，球钉在原地。改成存**真正喂出去的那个点**（feedPt），坏点只用一次。
    0.1.18：**整体照抄 TheBall**（用户定案）。反汇编对比后发现的根本差别：① 它的窗口是**全屏**的（`[UIScreen mainScreen].bounds`），球只是窗口里的一个子视图；我们以前把窗口做成「只有球那么大」，系统根本不会把触摸送进来。② 它的 `HUDMainWindow` 覆盖了 **9 个方法**，我们只有 3 个 —— 补上 `_isSecure`、`_shouldCreateContextAsSecure`、方向三个、以及「只把命中测试交给子视图、否则返回 nil」的 `hitTest`。③ 它的球**不用手势**，直接实现 `touchesBegan/Moved/Ended/Cancelled`，拿的是系统真触摸。这版起：球在全屏窗口里移动（拖动改球的位置，不再移动窗口），系统直接把触摸送进来；原先那套「从 HID 事件重建触摸」只留作后备（真点击一旦出现就自动停用）。
    0.1.17：① 修「只有第一下有用、后面点都不动」：抬起事件送不到时触点会一直攥着，后面的点击全被并成它的「移动」。现在三种情况都会先把上一轮结束再按新的处理 —— 事件断档 >0.15 秒、点跳了 >90pt（手指不会瞬移）、0.18 秒没新事件（原来 0.42 秒太长）。② 修「外观改了没反应」的**真正原因**：球每次写设置（点一下/拖完都会写）都把启动时读的旧快照整份写回，把 App 刚改的形状/颜色/大小/透明度盖掉了。现在只回写球自己负责的键（计数/位置/数字开关/落点），外观键以磁盘为准。③ 「关于」页诊断多一行「接管/喂球」累计数：接管不再涨而喂球在涨 = 触点卡住了。
    0.1.16：① 修「点一下之后球就卡死」：真机上「抬起」事件经常送不到，我们一直攥着假触点，后面的点击全被当成它的移动 —— 现在**断档 >0.15 秒就先补一个抬起**，另外 0.42 秒没新事件也会自己交还（比长按的 0.5 秒短，所以单击不会变成长按）。② 修「快速拖动时球跳到左上角」：空坐标事件 (0,0) 不再当成移动喂进去。③ 按下去球会**缩一下**（可见反馈）—— 真机确认 HUD 是后台进程，系统会把震动吞掉，光靠震动看不出「按到了」。④ 诊断多一行「结束=xxx」，能看出每次触摸是怎么结束的。⑤ 修「形状/颜色/大小/透明度改了没反应」：球每 2 秒比对一次外观文件的修改时间，变了就自己重新应用（不再只靠通知），「关于」页还加了**外观诊断**和一键「重新应用外观」。
    0.1.15：① 自喂测试证明「喂球这条路是通的」，所以问题只剩「这一下算不算按在球上」—— 这版把能拿到的坐标来源全用上（系统事件的点、每条手指路径自己的位置、底层子事件坐标的三种量纲），命中范围放宽到 10pt；起手也不再被「抬起」信号挡住。② 「关于」页新增**真实点球诊断**：点一下球，它会用一句人话告诉你「坐标在不在球上 / 有没有接管」，不用读数。③ 新增**盲喂**开关（默认关）：任何触摸都当点球（只震动计数、不执行动作），用来判断事件流里到底有没有真手指。④ 添加页搜索：一开始打字就只留「已安装的 App」一块（内置动作库/添加先收起来），搜出来的第一行就是 App 名字。
    0.1.14：① 触摸链找到根子了 —— 前几版读的是系统事件的**父事件**，手指状态（Touch / Range / 坐标）其实都在**子事件**上，所以「有手指」永远是 0、一次都没接管过球。这版会翻子事件去读（深读），并且不再把「读不到」当成「没手指」；起手落在球上也不再等系统那个从不出现的「按下」标志。② 「关于」页新增**自喂测试**：绕过 HID 检测，直接让球自己点一下 —— 球有反应＝喂球这条路通、毛病只在检测层；没反应＝喂球层不通。点一下就知道结论，不用你读数。
    0.1.13：① 快捷菜单的排序修好了 —— 长按一行（三条横线那头最顺手）往上拖，放到哪儿松手就定在哪儿，不用进什么编辑模式了（0.1.10 那条拖不动的老路整个删掉）。
    ② 添加页的搜索框：不再藏在导航栏里，改成 App 列表**头上的固定一行** —— 滑到列表里往上翻时它一直钉在最上面，随时能打字。
    0.1.12：① 震动只剩「强度」了 —— 「时长」滑块去掉（一律系统默认那一下，约 40 毫秒）。
    ② 「关于」页「原理来自」里那几个项目名变成**蓝色可点**了，点一下用浏览器打开它的项目主页。
    ③ 修了一个新报的 bug：把 App 删了，屏幕上的球还留着 —— 现在球每 3 秒确认一下「App 还在不在」，连续摸不到就自己消失（约 5~11 秒），不用重启了。
    ④ 球按下就震：以前要等手势判出来才震，手势一失灵按球就没一点动静；现在手一按上球就震，长按、动作执行仍然有各自的反馈。
    0.1.11：① 开关快了 —— 以前每次问「球在跑吗」都要在后台悄悄启动一整个程序，所以点了要等一两秒；现在球把自己的进程号写在 /tmp，App 读一下就够，松手即响应（顺手去掉了「状态」那一行，它没用）。
    ② 去掉「试一下震动」按钮：打开震动开关的那一下本身就会震，拖强度滑块也会当场震。
    ③ 触摸：真机自检显示「按下」这件事系统压根没告诉我们（30225 条事件里 0 次），老逻辑一直等它 —— 所以永远接不上。现在改成「手指第一次落在球上就算按下」。
    0.1.10：快捷菜单去掉右上角「编辑」（每行右边三条横线就是拖动手柄）；「添加」页中间多一栏「添加」，里面是「系统快捷指令」和「URL 协议」。
    点球没反应时，去「关于」页把「触摸自检」那几行念给我（0.1.11 起多了一行「底层」）。
    """

    /// 自检那两行的读法说明。
    /// ⚠️ 必须放在这里当成一个整体：直接写在 Section(footer:) 里拼接字符串，
    ///    Swift 类型检查会超时（CI 报 "unable to type-check this expression in reasonable time"）。
    private static let probeFooter = """
    第一行是「全局 HID 事件」那条链（0.1.3 起）：① 回调（路A = 老 BKS 回调，路B = 监视客户端）→ ② AX 转换 → ③ 手指路径 / 身份号 → ④ 起手在不在球上 → ⑤ 接管并喂给球。**接管**和**喂球**这两个数会一直涨 = 合成触摸这条路是通的。
    第二行是「真触摸 / 测试」：窗口问 = 系统问过窗口几次（0.1.19 起**长期是 0 才对** —— 我们刻意不让系统拿这个全屏窗口做命中测试）；落在球 = 其中落在球上的；真点击 = 球的手势一共触发了多少次；自喂测试 = 那个按钮做过几次。
    第三行「底层」（0.1.14 改）：深读 = 翻系统事件的**子事件**读手指状态（有手指 / 没手指 / 读不到）。
    第四行「最后」：最近一条事件的细节 —— 点 = 手指坐标，窗口点 = 换算后的坐标，球(窗口) = 球在窗口里的矩形，深读 / AX = 两套判据的原始值。
    哪个数不涨，断点就在哪。
    """

    // 0.1.38（用户 2026-10-20 要求）：各小节的说明都收进标题右边的 `*`（见 HelpNote.swift）。
    // ⚠️ 和上面 probeFooter 同一个规矩：长文案提成 static let，别内联在 body 里。
    private static let helpTapDiag = """
    去屏幕上**点一下球**，然后回这里看结论 —— 不用读数。
    它显示的是球进程收到的最近一条真实触摸：点在哪儿、球在哪儿、有没有被认成「按在球上」。每秒自动刷新。
    """

    private static let helpActionLog = """
    这两个动作靠「往系统注入按键/触摸」实现，手机上看不见任何提示，出问题只能看日志。
    先在屏幕上试一次，再点下面的刷新。
    """

    private static let helpStyle = """
    “图=包里的默认小圆点” 说明 App 画的贴图**没被球读到**（那就是写文件/通知那条链断了）；
    “图=App 画的贴图” 才是正常。点下面的按钮可以立刻重画一次并让球重读。

    （0.1.38 起「球直径」改报**实际用了多大** —— 闲置淡化的那几秒里它会比设定值小。）
    """

    private static let helpSelfTest = """
    它绕过 HID 检测，直接让球自己往球心喂一次「按下 + 抬起」。
    球会震一下（按下去那一下）、「真点击」+1 就是成功。这一步能把「检测层」和「喂球层」分开 ——
    点球没反应时先做这个，结论只有两种，都不用你读数。
    """

    /// 触摸自检：悬浮球进程（root 那个）把「HID 回调这条链子走到哪一步」写在 /tmp 里，
    /// App 直接读出来显示 —— 这样点球没反应时，不用开终端也能把这一行念出来。
    private var probeText: String {
        _ = probeTick
        return Self.readProbe()
    }

    private static func readProbe() -> String {
        let path = "/tmp/FloatingBall.probe"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "（读不到 /tmp/FloatingBall.probe）\n球进程可能没起来 —— 回「启动」页把开关关一下再打开。"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从自检文本里抠一个整数，例如 key="真点击" 时匹配 "真点击=3"。
    private static func probeInt(_ text: String, _ key: String) -> Int? {
        guard let r = text.range(of: key + "=") else { return nil }
        let digits = text[r.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    // ---- 外观诊断（0.1.16）----
    @State private var styleResult = ""

    private static func readStyle() -> [String: String] {
        guard let text = try? String(contentsOfFile: "/tmp/FloatingBall.style", encoding: .utf8) else {
            return [:]
        }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            if let idx = line.firstIndex(of: "=") {
                out[String(line[..<idx])] = String(line[line.index(after: idx)...])
            }
        }
        return out
    }

    private var styleDiag: [String: String] {
        _ = diagTick
        return Self.readStyle()
    }

    private func reapplyAppearance() {
        if let error = BallRenderer.regenerate() {
            styleResult = "重画失败：\(error)"
        } else {
            BallSettings.notifyReload()
            styleResult = "已重画贴图并让球重读。等 1~2 秒再看球有没有变；没变就把上面几行一起发我。"
        }
    }

    // ---- 自喂测试（0.1.14）----
    @State private var selfTestRunning = false
    @State private var selfTestResult = ""

    // ---- 截屏/全局返回的日志（0.1.23）----
    /// 这两个动作走的是「注入按键/触摸」，手机上看不见任何提示，
    /// 出问题只能靠日志。以前每次都得让用户开终端，太绕 ——
    /// 这里直接把球进程日志里相关的几行抠出来显示。
    private static func actionLogLines() -> [String] {
        guard let text = try? String(contentsOfFile: "/tmp/FloatingBall.log",
                                      encoding: .utf8) else { return [] }
        // ⚠️ 别用 text.split(separator: "\n") 再链 .map(String.init) ——
        // split 的 Element 在 Character / SubSequence 之间二义，链上 map 就报
        // ambiguous use of 'split(...)'（0.1.23 CI 实测挂在这儿）。
        // components(separatedBy:) 是 Foundation 的，直接给 [String]，没有二义。
        return Array(text.components(separatedBy: "\n")
            .filter { $0.contains("截屏") || $0.contains("全局返回") }
            .suffix(12))
    }

    private var actionLog: [String] {
        _ = actionLogTick
        return Self.actionLogLines()
    }

// ---- 真实点球诊断（0.1.15）----
    @State private var blindFeed = BallSettings.bool("BlindFeed", default: false)
    /// 0.1.26：`_ignoresHitTest` 的开关。默认 true = 吃掉触摸（不穿透），与 HUDMainWindow
    /// 运行时默认对齐（键不存在时返回 NO = 吃掉）。0.1.20~0.1.25 那几版默认关着是错误的。
    @State private var swallowTouch = BallSettings.bool("SwallowTouch", default: true)
    @State private var actionLogTick = 0
    @State private var diagTick = 0
    private let diagTicker = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    /// 每秒读一次诊断文件（diagTick 变了 body 才会重算）
    private var diag: [String: String] {
        _ = diagTick
        return Self.readDiag()
    }

    private static func readDiag() -> [String: String] {
        guard let text = try? String(contentsOfFile: "/tmp/FloatingBall.touchdiag", encoding: .utf8) else {
            return [:]
        }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            if let idx = line.firstIndex(of: "=") {
                out[String(line[..<idx])] = String(line[line.index(after: idx)...])
            }
        }
        return out
    }

    /// 把 diag 文件翻译成一句人话（不用用户读数）
    private static func verdict(_ d: [String: String]) -> String {
        guard !d.isEmpty else {
            return "还没有收到任何真实触摸事件 —— 先在屏幕上点球附近点几下，再回来看这里。"
        }
        let onBall = d["在球上"] == "1"
        let took = d["接管"] == "1"
        let raw = d["点"] ?? "?"
        let win = d["窗口点"] ?? "?"
        let ball = d["球窗口"] ?? "?"
        if onBall && took {
            let end = d["结束"] ?? "?"
            return "这一下被认成「按在球上」并且已经接管（球应该震一下）。上一次触摸结束方式：\(end)。"
        }
        if onBall {
            return "坐标是对的（这点确实在球上），但**没接管** —— 挡住的是起手判据，不是坐标。"
        }
        return "坐标没落在球上：点=(\(raw)) 窗口点=(\(win))，球在窗口里是 (\(ball))。"
    }

    /// 绕过 HID 检测层，直接让球进程往球心喂一次点击。
    /// 结果只看一件事：球的单击手势有没有被认出来（自检里「真点击」+1）。
    private func runSelfTest() {
        let beforeTap = Self.probeInt(Self.readProbe(), "真点击") ?? 0
        let beforeRun = Self.probeInt(Self.readProbe(), "自喂测试") ?? 0
        selfTestRunning = true
        selfTestResult = "已请求球进程喂一次点击……"

        FBPostNotify("com.daofeidao.notification.hud.selftest.tap")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            let text = Self.readProbe()
            let afterTap = Self.probeInt(text, "真点击") ?? 0
            let afterRun = Self.probeInt(text, "自喂测试") ?? 0
            selfTestRunning = false
            probeTick += 1

            if afterRun == beforeRun {
                selfTestResult = "球进程没收到请求（可能没在跑）—— 回「启动」页把开关关一下再打开，再试。"
            } else if afterTap > beforeTap {
                selfTestResult = "✅ 成功：球的手势认出来了。说明**喂球这条路是通的**，问题只在检测层（HID 事件没被认成「按在球上」）——把下面第三行「最后」那句念给我就行。"
            } else {
                selfTestResult = "❌ 没反应：触摸喂进了 UIKit，但没交到球上。问题在**喂球层**（不是检测层）——这一条比任何读数都关键，直接告诉我这个结果。"
            }
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    // 0.1.42（用户要求）：版本记录从首页搬到这里 —— 点这一行看历史。
                    Button {
                        showingVersion = true
                    } label: {
                        HStack {
                            Text("版本").foregroundColor(.primary)
                            Spacer()
                            Text(version).foregroundColor(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    // 0.1.42（用户要求）：点「标识」这一行打开本项目的 GitHub 页面。
                    Link(destination: URL(string: "https://github.com/daofeidao/FloatingBall")!) {
                        HStack {
                            Text("标识").foregroundColor(.primary)
                            Spacer()
                            Text("com.daofeidao.floatingball").foregroundColor(.secondary)
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: helpHeader("真实点球诊断（0.1.15）", Self.helpTapDiag)) {
                    Text(Self.verdict(diag))
                        .font(.footnote)

                    if !diag.isEmpty {
                        Text("深读=\(diag["深读"] ?? "?")   结束=\(diag["结束"] ?? "?")   接管/喂球=\(diag["累计接管"] ?? "?")/\(diag["累计喂球"] ?? "?")")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: helpHeader("截屏 / 全局返回 的执行记录（0.1.23）", Self.helpActionLog)) {
                    if actionLog.isEmpty {
                        Text("还没有相关记录 —— 先在屏幕上用一次「截屏」或「全局返回」。")
                            .font(.footnote)
                    } else {
                        ForEach(Array(actionLog.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption2, design: .monospaced))
                        }
                    }
                    Button("刷新记录") { actionLogTick += 1 }
                }

                Section(header: Text("穿透（0.1.20 新增，先关着）"),
                        footer: Text("打开后系统会拿我们这个窗口做命中测试，点在球上的那一下**理论上**就不漏给下面的 App 了（TheBall 就是这么做到的）。\n\n⚠️ 代价：万一系统仍然不把真触摸派发给球，整块屏幕会变成哑巴（什么都点不动）。真那样的话：长按「电源 + 音量减」强制重启，然后把这个开关关掉。\n\n球不需要重启，开关改完 1 秒内自动生效。")) {
                    Toggle("吃掉触摸（不穿透）", isOn: $swallowTouch)
                        .onChange(of: swallowTouch) { value in
                            BallSettings.set(value, "SwallowTouch")
                            BallSettings.notifyReload()
                        }
                }

                Section(header: Text("盲喂（验证用，平时关掉）"),
                        footer: Text("打开后：屏幕上**任何地方**的触摸都会被当成点球（只震动+计数，不执行绑定的动作）。\n用途：如果盲喂时球有反应 → 说明事件流里有真手指，只是坐标对不上；如果盲喂也没反应 → 说明事件流里根本没有手指，得换一条路。")) {
                    Toggle("盲喂：任何触摸都当点球", isOn: $blindFeed)
                        .onChange(of: blindFeed) { value in
                            BallSettings.set(value, "BlindFeed")
                            BallSettings.notifyReload()
                        }
                }

                Section(header: helpHeader("外观诊断（0.1.16）", Self.helpStyle)) {
                    if styleDiag.isEmpty {
                        Text("还没读到（球进程没起来？）").font(.footnote)
                    } else {
                        Text("球现在用的是：\(styleDiag["图"] ?? "?")；直径 \(styleDiag["球直径"] ?? "?")；透明度 \(styleDiag["球_alpha"] ?? "?")")
                            .font(.footnote)
                        Text("形状=\(styleDiag["形状"] ?? "?")  颜色=\(styleDiag["颜色"] ?? "?")  贴图时间=\(styleDiag["贴图时间"] ?? "?")")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Button("重新应用外观") { reapplyAppearance() }
                    if !styleResult.isEmpty {
                        Text(styleResult).font(.footnote).foregroundColor(.secondary)
                    }
                }

                Section(header: helpHeader("自喂测试（先点这个）", Self.helpSelfTest)) {
                    Button {
                        runSelfTest()
                    } label: {
                        HStack {
                            Text("让球自己点一下")
                            Spacer()
                            if selfTestRunning { ProgressView() }
                        }
                    }
                    .disabled(selfTestRunning)

                    if !selfTestResult.isEmpty {
                        Text(selfTestResult)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: helpHeader("触摸自检（点球没反应时看这里）", Self.probeFooter)) {
                    Text(probeText)
                        .font(.system(.caption, design: .monospaced))
                    Button("刷新") { probeTick += 1 }
                }

                Section(header: Text("这个 App 怎么工作")) {
                    Text("它启动后会把自己再拉起一次，这次以 root 身份常驻，并带着辅助触控（系统小白点）那一组系统权限，因此能把一个圆画在所有 App 之上。")
                        .font(.footnote)
                }

                Section(header: Text("原理来自"),
                        footer: Text("点项目名会用浏览器打开它的主页。本项目基于 Helium 的骨架，沿用 GPL-3.0 授权。")) {
                    credit("Lessica / TrollSpeed", "最早证明 TrollStore 免越狱能画全局悬浮窗",
                           "https://github.com/Lessica/TrollSpeed")
                    credit("limneos / UIDaemon", "「一个能画在 SpringBoard 之上的 iOS 守护进程」",
                           "https://github.com/limneos/UIDaemon")
                    credit("leminlimez / Helium", "本项目直接沿用了它的 HUD 骨架（GPL-3.0）",
                           "https://github.com/leminlimez/Helium")
                    credit("hhse / TheBall", "同类成品，本项目参考了它的交互设计",
                           "https://github.com/hhse/TheBall")
                }
            }
            .navigationTitle("关于")
            .onReceive(diagTicker) { _ in
                diagTick += 1
            }
            // 0.1.42：点「版本」那一行弹这张历史表（内容见 versionHistory）
            .sheet(isPresented: $showingVersion) {
                NavigationView {
                    ScrollView {
                        Text(Self.versionHistory)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding()
                    }
                    .navigationTitle("版本记录")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("好") { showingVersion = false }
                        }
                    }
                }
            }
        }
    }

    /// 一行「原理来自」：项目名是**蓝色可点的链接**，点了用系统浏览器打开项目主页。
    ///
    /// ⚠️ 用 `Link` 而不是 `Button` + `UIApplication.open`：
    ///    它就是「打开一个 URL」的语义，SwiftUI 自己会按 tint 染蓝、还支持长按预览；
    ///    而 `Button` 在 List 行里会多一层整行高亮，反而不好看。
    ///    http(s) 走系统默认处理器 = **Safari**；这里不需要 `FBOpenURL`（那是给 scheme 用的）。
    private func credit(_ title: String, _ detail: String, _ url: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let link = URL(string: url) {
                Link(destination: link) {
                    HStack(spacing: 5) {
                        Text(title)
                            .foregroundColor(.blue)
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                }
            } else {
                Text(title)
            }
            Text(detail).font(.caption).foregroundColor(.secondary)
        }
    }
}
